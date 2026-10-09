"""
SIGADI - lancador do servidor (usado pelo systemd: run_sigadi.py <porta>).
Serve o handler do servidor.py na porta recebida (padrao 80), com uma
thread por conexao.
"""
import os
import sys

# Sem console (ex.: pythonw no Windows) sys.stdout/sys.stderr sao None e o
# log de acesso/print estouraria. Redireciona para um arquivo de log.
BASE = os.path.dirname(os.path.abspath(__file__))
os.chdir(BASE)
if sys.stderr is None or sys.stdout is None:
    _log = open(os.path.join(BASE, "sigadi_servidor.log"), "a", buffering=1, encoding="utf-8")
    if sys.stdout is None:
        sys.stdout = _log
    if sys.stderr is None:
        sys.stderr = _log

import servidor

port = int(sys.argv[1]) if len(sys.argv) > 1 else 80
httpd = servidor.criar_servidor(port)
httpd.serve_forever()
