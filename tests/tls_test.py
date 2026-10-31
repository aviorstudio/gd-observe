"""Check custom system trust roots and reject an untrusted WSS endpoint."""
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import unittest

PRODUCT = 'gdobs'
ROOT = Path(__file__).resolve().parents[1]
TARGET = Path(os.environ.get('CARGO_TARGET_DIR', ROOT/'cli/target'))
BINARY = Path(os.environ.get('TLS_TEST_BINARY', TARGET/'debug'/PRODUCT)).resolve()


def receive(stream, count):
    out = b''
    while len(out) < count:
        part = stream.recv(count-len(out))
        if not part:
            raise EOFError('closed WebSocket')
        out += part
    return out


@unittest.skipUnless(platform.system() == 'Linux' and shutil.which('openssl'), 'Linux SSL_CERT_FILE trust contract')
class TLS(unittest.TestCase):
    def test_system_root_override_and_untrusted_certificate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key, cert, empty = (root/name for name in ('key.pem','root.pem','empty.pem'))
            empty.write_text('')
            (root/'certs').mkdir()
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
                            '-keyout',str(key),'-out',str(cert),'-subj','/CN=CLI test trust root',
                            '-addext','subjectAltName=DNS:localhost,IP:127.0.0.1',
                            '-addext','basicConstraints=critical,CA:TRUE'],
                           check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
            leaf_key, request, leaf, extensions = (root/name for name in ('server.key','server.csr','server.pem','server.ext'))
            extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n')
            subprocess.run(['openssl','req','-new','-newkey','rsa:2048','-nodes','-keyout',str(leaf_key),'-out',str(request),'-subj','/CN=localhost'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
            subprocess.run(['openssl','x509','-req','-in',str(request),'-CA',str(cert),'-CAkey',str(key),'-CAcreateserial','-days','1','-extfile',str(extensions),'-out',str(leaf)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(leaf,leaf_key)
            for trusted in (True,False):
                with self.subTest(trusted=trusted), socket.socket() as listener:
                    listener.bind(('127.0.0.1',0))
                    listener.listen()
                    listener.settimeout(5)
                    calls=[]
                    errors=[]
                    def serve():
                        try:
                            stream,_ = listener.accept()
                            stream.settimeout(3)
                            with context.wrap_socket(stream,server_side=True) as peer:
                                headers=b''
                                while b'\r\n\r\n' not in headers:
                                    headers+=peer.recv(4096)
                                    if len(headers)>32768:
                                        raise AssertionError('oversized upgrade request')
                                values=dict(line.split(':',1) for line in headers.decode().split('\r\n')[1:] if ':' in line)
                                nonce=next(value.strip() for name,value in values.items() if name.lower()=='sec-websocket-key')
                                accept=base64.b64encode(hashlib.sha1((nonce+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                                peer.sendall(f'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n'.encode())
                                first,second=receive(peer,2)
                                length=second&127
                                if length==126:
                                    length=struct.unpack('!H',receive(peer,2))[0]
                                elif length==127:
                                    length=struct.unpack('!Q',receive(peer,8))[0]
                                assert first&15==1 and second&128 and length<32768
                                mask=receive(peer,4)
                                data=receive(peer,length)
                                request=json.loads(bytes(value^mask[index%4] for index,value in enumerate(data)))
                                calls.append(request)
                                if PRODUCT=='gdobs':
                                    assert request['type']=='snapshot_request'
                                    response=dict(type='snapshot',request_id=request['request_id'],enabled=True,metric_count=1)
                                else:
                                    assert request['method']=='Runtime.evaluate'
                                    response=dict(id=request['id'],result=dict(result=dict(value=json.dumps(dict(test_state=dict(fixture=dict(ready=True)))))))
                                data=json.dumps(response).encode()
                                peer.sendall(bytes([0x81,len(data)])+data if len(data)<126 else bytes([0x81,126])+struct.pack('!H',len(data))+data)
                        except (ssl.SSLError,EOFError):
                            pass
                        except Exception as error:
                            errors.append(str(error))
                    thread=threading.Thread(target=serve,daemon=True)
                    thread.start()
                    endpoint=f'wss://localhost:{listener.getsockname()[1]}'
                    args=['snapshot','--addr',endpoint,'--timeout','2s'] if PRODUCT=='gdobs' else ['state','--cdp',endpoint]
                    env=dict(os.environ,SSL_CERT_FILE=str(cert if trusted else empty),SSL_CERT_DIR=str(root/'certs'))
                    env.pop('GDOBS_AUTH_TOKEN',None)
                    result=subprocess.run([str(BINARY),*args],env=env,capture_output=True,text=True,timeout=5)
                    thread.join(timeout=5)
                    self.assertFalse(thread.is_alive())
                    self.assertEqual(errors,[])
                    self.assertEqual(result.returncode==0,trusted,result.stderr)
                    self.assertEqual(len(calls),1 if trusted else 0)
                    if trusted:
                        self.assertIsInstance(json.loads(result.stdout),dict)


if __name__=='__main__':
    unittest.main(verbosity=2)
