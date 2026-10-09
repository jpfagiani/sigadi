import os
import json
import shutil
import socket
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import gzip
import hashlib

PORT = 5000
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_FILE = os.path.join(BASE_DIR, 'sigadi_dados.json')
DB_FILE_LEGADO = os.path.join(BASE_DIR, 'sgf_dados.json')  # nome antigo (antes de SGF virar SIGADI)
UNIDADE_CONF = os.path.join(BASE_DIR, 'unidade.conf')
db_lock = threading.Lock()

# Nome da unidade fica FORA do index.html e fora do git — nada de editar o
# HTML por unidade. O instalador escreve unidade.conf (texto simples,
# UNIDADE_NOME=valor por linha); sem o arquivo, cai nos valores da unidade
# onde o SGF nasceu, só para uma instalação de teste não ficar em branco.
_UNIDADE_PADRAO = {
    'UNIDADE_NOME': 'Centro de Detenção Provisória de Nova Independência',
    'UNIDADE_CIDADE_UF': 'Nova Independência/SP',
    'UNIDADE_COORDENADORIA': 'Coordenadoria das Unidades Prisionais da Região Oeste do Estado',
    'UNIDADE_CHEFE_NOME': 'RODRIGO CARLOS BORGES',
    'UNIDADE_CHEFE_CARGO': 'Chefe de Departamento',
}

def carregar_config_unidade():
    valores = dict(_UNIDADE_PADRAO)
    try:
        with open(UNIDADE_CONF, 'r', encoding='utf-8') as f:
            for linha in f:
                linha = linha.strip()
                if not linha or linha.startswith('#') or '=' not in linha:
                    continue
                chave, _, valor = linha.partition('=')
                valores[chave.strip()] = valor.strip()
    except FileNotFoundError:
        pass
    # Derivadas, não configuráveis: os documentos impressos (FCT, Ordem de
    # Saída) seguem a convenção de cabeçalho institucional em caixa alta.
    valores['UNIDADE_NOME_MAIUSCULA'] = valores['UNIDADE_NOME'].upper()
    valores['UNIDADE_CIDADE_UF_MAIUSCULA'] = valores['UNIDADE_CIDADE_UF'].upper()
    return valores

def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('10.255.255.255', 1))
        IP = s.getsockname()[0]
    except Exception:
        IP = '127.0.0.1'
    finally:
        s.close()
    return IP

def obter_dados_padrao():
    return {
        "motoristas": [
            { "nome": "Cláudio Mendonça", "rg": "12.345.678-9", "categoria": "D", "telefone": "(11) 99999-1111", "ativo": True, "viajaSP": True, "viajaInterior": True },
            { "nome": "Juliana Peixoto", "rg": "98.765.432-1", "categoria": "B", "telefone": "(11) 99999-2222", "ativo": True, "viajaSP": True, "viajaInterior": False },
            { "nome": "Carlos Silva", "rg": "45.123.890-X", "categoria": "E", "telefone": "(11) 99999-3333", "ativo": True, "viajaSP": False, "viajaInterior": True }
        ],
        "viaturas": [
            { "veiculo": "Caminhonete", "modelo": "Chevrolet S10", "placa": "ABC-1234" },
            { "veiculo": "Sedan", "modelo": "Toyota Corolla", "placa": "SGF-2026" }
        ],
        "servicos": [
            { "nome": "Entrega / Logística" },
            { "nome": "Manutenção de Campo" },
            { "nome": "Reunião / Visita Comercial" },
            { "nome": "Administrativo" }
        ],
        "viagensFCT": [],
        "historicoVez": [],
        "pulos": [],
        "servidores": [],
        "trocasOleo": [],
        "abastecimentos": [],
        "manutencoes": [],
        "checksViatura": [],
        "usuarios": [{ "login": "master", "nome": "Administrador Master", "senha": "MTIzNDU2", "nivel": "Master" }],
        "pos_sp": 0,
        "pos_interior": 0,
        "mapaForca": [],
        "romaneios": [],
        "documentosTemporalidade": []
    }

# ─────────────────────────────────────────────────────────────────────────
#  Cache em memória
#
#  O servidor antigo relia e revalidava (json.loads) o banco inteiro a cada
#  GET — e o painel consulta /api/dados a cada 5 s por usuário. Agora o
#  arquivo só é relido/parseado quando muda (mtime/tamanho), e a resposta
#  sai comprimida (gzip) e com ETag (304 quando nada mudou).
# ─────────────────────────────────────────────────────────────────────────
_db_cache = {'sig': None, 'raw': b'', 'gz': None, 'etag': '', 'versao': 0, 'modificadoEm': None}
_db_ruim_sig = None          # assinatura do último arquivo ilegível (evita copiar a cada poll)
_estaticos = {}              # caminho -> dict(sig, raw, gz, etag)
_index_cache = {'sig': None, 'raw': b'', 'gz': b'', 'etag': ''}
_cache_lock = threading.Lock()

EXT_ESTATICAS = {
    '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8', '.png': 'image/png',
    '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.ico': 'image/x-icon',
    '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.woff': 'font/woff',
    '.ttf': 'font/ttf',
}
COMPRIMIVEIS = ('.html', '.css', '.js', '.svg', '.ttf')


def migrar_banco_legado():
    """Instalações antigas guardavam o banco como sgf_dados.json. Se o novo
    nome ainda não existe, renomeia (sem nunca sobrescrever um banco novo)."""
    try:
        if not os.path.exists(DB_FILE) and os.path.exists(DB_FILE_LEGADO):
            os.rename(DB_FILE_LEGADO, DB_FILE)
            print(f"Banco legado renomeado: {DB_FILE_LEGADO} -> {DB_FILE}")
    except Exception as e:
        print(f"Aviso: não foi possível renomear o banco legado: {e}")


def _sig(path):
    st = os.stat(path)
    return (st.st_mtime_ns, st.st_size)


def _etag(raw):
    return '"' + hashlib.md5(raw).hexdigest() + '"'


def ler_banco():
    """Devolve o cache do banco (atualizado se o arquivo mudou). Usa o db_lock
    internamente. Levanta exceção se o arquivo existe mas
    não pode ser lido/validado — nunca recria o banco por cima de um existente."""
    global _db_ruim_sig
    with db_lock:
        if not os.path.exists(DB_FILE):
            migrar_banco_legado()
        if not os.path.exists(DB_FILE):
            # Primeira instalação de verdade: cria o banco padrão.
            _gravar_atomico(obter_dados_padrao())
        sig = _sig(DB_FILE)
        if _db_cache['sig'] == sig:
            return _db_cache
        try:
            with open(DB_FILE, 'rb') as f:
                raw = f.read()
            dados = json.loads(raw.decode('utf-8'))   # valida uma vez por alteração
        except Exception as e:
            # NUNCA gerar/gravar o banco padrão por cima de um arquivo que já
            # existe: uma falha passageira de leitura já apagou o banco real
            # duas vezes assim. Falha alto e visível.
            print(f"ERRO CRÍTICO ao ler {DB_FILE}: {e}")
            if _db_ruim_sig != sig:
                _db_ruim_sig = sig
                try:
                    copia = f"{DB_FILE}.corrompido.{int(time.time())}"
                    shutil.copy(DB_FILE, copia)
                    print(f"Cópia do arquivo problemático preservada em: {copia}")
                except Exception as e2:
                    print(f"Não foi possível preservar cópia do arquivo problemático: {e2}")
            raise
        _atualizar_cache_db(sig, raw, dados)
        return _db_cache


def _atualizar_cache_db(sig, raw, dados):
    _db_cache.update(
        sig=sig, raw=raw, gz=None, etag=_etag(raw),
        versao=(dados.get('versao', 0) if isinstance(dados, dict) else 0),
        modificadoEm=(dados.get('modificadoEm') if isinstance(dados, dict) else None))


def _gravar_atomico(payload):
    """Escrita atômica (arquivo temporário + rename). Chamar com db_lock."""
    raw = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    dir_name = os.path.dirname(DB_FILE)
    tempname = None
    try:
        with tempfile.NamedTemporaryFile('wb', dir=dir_name, delete=False) as tf:
            tempname = tf.name
            tf.write(raw)
            tf.flush()
            os.fsync(tf.fileno())
        os.replace(tempname, DB_FILE)
        tempname = None
    finally:
        if tempname and os.path.exists(tempname):
            os.unlink(tempname)
    _atualizar_cache_db(_sig(DB_FILE), raw, payload)


def _gz(raw):
    return gzip.compress(raw, compresslevel=6, mtime=0)


def _estatico(caminho, ext):
    """Arquivo estático em cache (relê só se mudou)."""
    sig = _sig(caminho)
    with _cache_lock:
        item = _estaticos.get(caminho)
        if item and item['sig'] == sig:
            return item
        with open(caminho, 'rb') as f:
            raw = f.read()
        item = {'sig': sig, 'raw': raw, 'etag': _etag(raw),
                'gz': _gz(raw) if ext in COMPRIMIVEIS and len(raw) > 512 else None}
        _estaticos[caminho] = item
        return item


def _index_renderizado():
    """index.html com os marcadores da unidade já trocados — cacheado e só
    refeito quando index.html ou unidade.conf mudam."""
    caminho = os.path.join(BASE_DIR, 'index.html')
    try:
        conf_sig = _sig(UNIDADE_CONF)
    except OSError:
        conf_sig = None
    sig = (_sig(caminho), conf_sig)
    with _cache_lock:
        if _index_cache['sig'] == sig:
            return _index_cache
        with open(caminho, 'r', encoding='utf-8') as f:
            conteudo = f.read()
        for chave, valor in carregar_config_unidade().items():
            conteudo = conteudo.replace('{{' + chave + '}}', valor)
        raw = conteudo.encode('utf-8')
        _index_cache.update(sig=sig, raw=raw, gz=_gz(raw), etag=_etag(raw))
        return _index_cache


class SIGADIRequestHandler(BaseHTTPRequestHandler):
    # HTTP/1.1 = conexão persistente: o navegador reaproveita o socket para
    # index, scripts, fontes e API em vez de abrir uma conexão por arquivo.
    protocol_version = 'HTTP/1.1'
    timeout = 60   # derruba conexões ociosas (não deixa threads presas)

    def log_request(self, code='-', size='-'):
        # Só registra erros: um log por poll/arquivo estático lota o journal.
        try:
            if int(code) >= 400:
                super().log_request(code, size)
        except (TypeError, ValueError):
            super().log_request(code, size)

    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        super().end_headers()

    def _responder(self, ctype, raw, gz=None, etag=None, cache='no-cache', status=200, head=False):
        if etag and self.headers.get('If-None-Match') == etag:
            self.send_response(304)
            self.send_header('ETag', etag)
            self.send_header('Cache-Control', cache)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        corpo = raw
        usa_gz = gz is not None and 'gzip' in self.headers.get('Accept-Encoding', '')
        if usa_gz:
            corpo = gz
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        if gz is not None:
            self.send_header('Vary', 'Accept-Encoding')
        if usa_gz:
            self.send_header('Content-Encoding', 'gzip')
        if etag:
            self.send_header('ETag', etag)
        self.send_header('Cache-Control', cache)
        self.send_header('Content-Length', str(len(corpo)))
        self.end_headers()
        if not head:
            self.wfile.write(corpo)

    def do_OPTIONS(self):
        self.send_response(200, "OK")
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_HEAD(self):
        self.do_GET(head=True)

    def do_GET(self, head=False):
        path = self.path.split('?')[0]

        if path == '/api/versao':
            # Consulta leve para o painel saber se algo mudou sem baixar o banco.
            try:
                c = ler_banco()
                corpo = json.dumps({'versao': c['versao'], 'modificadoEm': c['modificadoEm']}).encode('utf-8')
            except Exception:
                self.send_error(500, "Banco de dados existente nao pode ser lido. Nada foi sobrescrito, veja o log do servidor.")
                return
            self._responder('application/json; charset=utf-8', corpo, cache='no-store', head=head)
            return

        if path == '/api/dados':
            try:
                c = ler_banco()
                if c['gz'] is None:
                    c['gz'] = _gz(c['raw'])
                raw, gz, etag = c['raw'], c['gz'], c['etag']
            except Exception:
                self.send_error(500, "Banco de dados existente nao pode ser lido. Nada foi sobrescrito, veja o log do servidor.")
                return
            self._responder('application/json; charset=utf-8', raw, gz=gz, etag=etag,
                            cache='no-cache', head=head)
            return

        if path in ('/', '/index.html'):
            try:
                c = _index_renderizado()
            except FileNotFoundError:
                self.send_error(404, "Arquivo não encontrado")
                return
            self._responder('text/html; charset=utf-8', c['raw'], gz=c['gz'], etag=c['etag'],
                            cache='no-cache', head=head)
            return

        # Estáticos: só extensões permitidas, na raiz ou dentro de /vendor/.
        # Nunca serve banco, código, logs, scripts ou unidade.conf.
        rel = os.path.normpath(path.lstrip('/'))
        partes = rel.split(os.sep)
        ext = os.path.splitext(rel)[1].lower()
        permitido = (
            ext in EXT_ESTATICAS and '..' not in partes and not os.path.isabs(rel) and
            (len(partes) == 1 or (partes[0] == 'vendor' and len(partes) <= 4))
        )
        if not permitido:
            if ext in ('.json', '.db', '.key', '.log', '.py', '.bak', '.conf', '.sh'):
                self.send_error(403, "Acesso negado")
            else:
                self.send_error(404, "Arquivo não encontrado")
            return
        caminho = os.path.join(BASE_DIR, rel)
        real = os.path.realpath(caminho)
        if not real.startswith(os.path.realpath(BASE_DIR) + os.sep) or not os.path.isfile(real):
            self.send_error(404, "Arquivo não encontrado")
            return
        item = _estatico(real, ext)
        # Logos, fontes e bibliotecas quase nunca mudam: o navegador guarda
        # por 1 dia e revalida por ETag depois.
        self._responder(EXT_ESTATICAS[ext], item['raw'], gz=item['gz'], etag=item['etag'],
                        cache='public, max-age=86400', head=head)

    def do_POST(self):
        if self.path.split('?')[0] != '/api/dados':
            self.send_error(404, "Rota não encontrada")
            return
        try:
            content_length = int(self.headers.get('Content-Length', 0))
        except ValueError:
            content_length = 0
        if content_length <= 0 or content_length > 200 * 1024 * 1024:
            self.send_error(400, "Dados JSON inválidos ou erro de gravação")
            return
        post_data = self.rfile.read(content_length)
        try:
            # Valida o payload antes de salvar
            payload = json.loads(post_data.decode('utf-8'))
            with db_lock:
                _gravar_atomico(payload)
        except Exception as e:
            print(f"Erro ao salvar dados recebidos: {e}")
            self.send_error(400, "Dados JSON inválidos ou erro de gravação")
            return
        self._responder('application/json; charset=utf-8', b'{"status": "ok"}', cache='no-store')


# Nome antigo mantido: um run_sgf.py anterior (instalação não migrada) continua funcionando.
SGFRequestHandler = SIGADIRequestHandler


class SIGADIServer(ThreadingHTTPServer):
    """Uma thread por conexão: um download lento (ou uma conexão presa) não
    trava mais todos os outros usuários, como no HTTPServer de uma thread."""
    daemon_threads = True
    request_queue_size = 128
    allow_reuse_address = True

    def server_bind(self):
        # HTTPServer.server_bind chama socket.getfqdn() — uma consulta DNS
        # reversa que pode levar vários segundos numa rede sem DNS. Não usamos
        # o nome para nada, então pula.
        import socketserver
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def criar_servidor(porta):
    migrar_banco_legado()
    return SIGADIServer(('0.0.0.0', porta), SIGADIRequestHandler)


def run():
    httpd = criar_servidor(PORT)
    local_ip = get_local_ip()

    print("=" * 70)
    print(" SIGADI - Sistema Interno de Gestão Administrativa Integrada está ATIVO na rede local!")
    print("-" * 70)
    print(f" Para acessar de outros computadores da mesma rede, digite:")
    print(f" http://{local_ip}:{PORT}/")
    print("-" * 70)
    print(f" Para acessar nesta máquina servidora local, digite:")
    print(f" http://localhost:{PORT}/")
    print("=" * 70)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nServidor finalizado pelo usuário.")
        httpd.server_close()

if __name__ == '__main__':
    run()
