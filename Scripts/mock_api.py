#!/usr/bin/env python3
"""Loopback-only API fixture. Uses synthetic content and no real credentials."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        model = body['model']
        if model == 'reject-pdf':
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"This model does not support file inputs"}}')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        try:
            if self.path.endswith('/responses'):
                continued = any(item.get('type') == 'function_call_output' for item in body['input'])
                if continued:
                    assert any(item.get('type') == 'reasoning' for item in body['input'])
                    assert any(item.get('output') == 'page content' for item in body['input'])
                    self.event({'type': 'response.output_text.delta', 'delta': 'Responses tool success'})
                    self.event({'type': 'response.completed', 'response': {'output': [], 'usage': {'input_tokens': 10, 'output_tokens': 5}}})
                else:
                    parts = body['input'][-1]['content']
                    assert parts[0]['type'] == 'input_file'
                    output = [{'type': 'reasoning', 'id': 'rs_1', 'summary': []}, {'type': 'function_call', 'id': 'fc_1', 'call_id': 'c1', 'name': 'read_pdf_page', 'arguments': '{"page":1}'}]
                    self.event({'type': 'response.output_item.done', 'output_index': 1, 'item': output[1]})
                    self.event({'type': 'response.completed', 'response': {'output': output, 'usage': {'input_tokens': 20, 'output_tokens': 4}}})
            elif model == 'tool-chat':
                continued = any(item['role'] == 'tool' for item in body['messages'])
                if continued:
                    assert body['messages'][-1]['content'] == 'page content'
                    self.chat_text('Chat tool success')
                else:
                    parts = body['messages'][-1]['content']
                    assert parts[0]['type'] == 'file'
                    self.event({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'c1', 'function': {'name': 'read_pdf_page', 'arguments': '{"pa'}}]}}]})
                    self.event({'choices': [{'delta': {'tool_calls': [{'index': 0, 'function': {'arguments': 'ge":1}'}}]}, 'finish_reason': 'tool_calls'}]})
                    self.event('[DONE]')
            elif model == 'demo':
                text = "这份文档用三个页面展示了一个简洁的阅读流程。\n\n## 核心内容\n\n1. 阅读正文，保留当前位置。\n2. 引用段落向助手提问。\n3. 返回原文核对回答。\n\n图中三组柱形表示不同的示例数据，来源是 [第 2 页](pdfchat://page/2)。\n\n| 项目 | 说明 |\n|---|---|\n| 文档输入 | 完整 PDF 或 PDFKit 文字 |\n| 工具 | 搜索、读页、查看图像 |\n| 输出 | 流式 Markdown 与公式 |\n\n示例公式：\n\n$$E = mc^2$$\n\n" + "\n\n".join("补充说明 %d：这里是用于检查滚动和长回答排版的合成内容。阅读旧段落时，新内容不会强制拉动滚动位置。" % i for i in range(1, 12))
                for i in range(0, len(text), 12):
                    self.event({'choices': [{'delta': {'content': text[i:i+12]}}]})
                    time.sleep(0.04)
                self.event({'choices': [{'delta': {}, 'finish_reason': 'stop'}]})
                self.event({'choices': [], 'usage': {'prompt_tokens': 1200, 'completion_tokens': 350}})
                self.event('[DONE]')
            elif model == 'slow':
                self.event({'choices': [{'delta': {'content': 'old stream'}}]})
                time.sleep(0.5)
                self.chat_text(' stale suffix')
            elif model == 'broken':
                self.event({'choices': [{'delta': {'content': 'partial answer'}}]})
            else:
                self.chat_text('fresh answer')
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            self.event({'error': {'message': 'Fixture assertion: ' + repr(error)}})

    def event(self, value):
        value = value if isinstance(value, str) else json.dumps(value)
        # Deliberately fragment the HTTP byte stream independently of SSE frames.
        data = ('data: ' + value + '\n\n').encode()
        for i in range(0, len(data), 7):
            self.wfile.write(data[i:i+7])
        self.wfile.flush()

    def chat_text(self, text):
        for part in [text[:4], text[4:]]:
            self.event({'choices': [{'delta': {'content': part}}]})
        self.event({'choices': [{'delta': {}, 'finish_reason': 'stop'}]})
        self.event({'choices': [], 'usage': {'prompt_tokens': 30, 'completion_tokens': 5}})
        self.event('[DONE]')

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
