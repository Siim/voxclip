import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    polls = 0
    creates = 0

    def log_message(self, *_):
        pass

    def respond(self, status, value):
        payload = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        assert self.headers.get('Cookie') is None
        assert self.headers.get('Authorization') == 'Bearer fixture-session'
        if self.path == '/api/auth/get-session':
            return self.respond(200, {'user': {'id': 'creator'}})
        if self.path == '/video-job/11111111-1111-1111-1111-111111111111':
            return self.respond(200, {'status': 'completed', 's3Url': 'https://media.example.test/post.mp4'})
        return self.respond(404, {})

    def do_POST(self):
        assert self.headers.get('Cookie') is None
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/api/auth/device/code':
            assert json.loads(body) == {'client_id': 'voxclip', 'scope': 'post:video'}
            assert self.headers.get('Authorization') is None
            return self.respond(200, {'user_code': 'ABCD1234', 'device_code': 'fixture-device', 'expires_in': 600,
                                      'interval': 5, 'verification_uri': 'https://not-the-web-origin.example.test/'})
        if self.path == '/api/auth/device/token':
            assert json.loads(body) == {'client_id': 'voxclip', 'device_code': 'fixture-device',
                                       'grant_type': 'urn:ietf:params:oauth:grant-type:device_code'}
            assert self.headers.get('Authorization') is None
            Handler.polls += 1
            if Handler.polls <= 2:
                return self.respond(400, {'error': ('authorization_pending', 'slow_down')[Handler.polls - 1]})
            errors = {'denied': 'access_denied', 'expired': 'expired_token'}
            if sys.argv[1] in errors:
                return self.respond(400, {'error': errors[sys.argv[1]]})
            scope = 'post:video account:write' if sys.argv[1] == 'wrong-scope' else 'post:video'
            return self.respond(200, {'access_token': 'fixture-session', 'token_type': 'Bearer', 'scope': scope})
        assert self.headers.get('Authorization') == 'Bearer fixture-session'
        if self.path == '/api/auth/sign-out':
            return self.respond(200, {'success': True})
        if self.path == '/upload-video':
            assert self.headers.get('Content-Type').startswith('multipart/form-data; boundary=')
            assert b'name="prerendered"\r\n\r\ntrue\r\n' in body
            assert b'name="words"\r\n\r\n[]\r\n' in body
            assert b'name="transcript"\r\n\r\nEdited words\r\n' in body
            assert b'Content-Type: video/mp4\r\n\r\nfixture media bytes\r\n' in body
            return self.respond(200, {'success': True, 'jobId': '11111111-1111-1111-1111-111111111111'})
        if self.path == '/graphql':
            request = json.loads(body)
            if 'getMyAccount' in request['query']:
                return self.respond(200, {'data': {'getMyAccount': {'accountId': 25, 'handle': 'creator', 'name': 'Creator'}}})
            Handler.creates += 1
            assert 'createNew(newPostData: $d)' in request['query']
            post = request['variables']['d']
            assert post['video'] == {'converted': 'https://media.example.test/post.mp4'}
            assert post['transcript'] == 'Edited words'
            assert post['text'] == 'Ready to share.'
            assert json.loads(post['wordTimestamps']) == [{'word': 'Edited', 'start': 0, 'end': 0.5, 'conf': None}]
            if sys.argv[1] == 'redirect':
                self.send_response(307)
                self.send_header('Location', '/unexpected-post')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            if sys.argv[1] == 'uncertain' and Handler.creates == 1:
                return self.respond(503, {})
            return self.respond(200, {'data': {'createNew': {'postId': Handler.creates, 'handle': 'creator'}}})
        if self.path == '/unexpected-post':
            return self.respond(200, {'data': {'createNew': {'postId': 99}}})
        return self.respond(404, {})


with HTTPServer(('127.0.0.1', 0), Handler) as server:
    print(server.server_port, flush=True)
    server.serve_forever()
