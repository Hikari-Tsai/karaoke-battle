// OBS overlay: a tiny local HTTP + WebSocket server. Add
// http://127.0.0.1:<port>/ as a Browser Source in OBS; the page draws the
// scrolling piano roll + live F0 + score from the JSON the app broadcasts.
//
// Messages (JSON objects) the app sends:
//   {"type":"song","title":..,"notes":[{"onset","offset","pitch"}],"shift":0}
//   {"type":"tick","t":12.34,"f0":[[t,f0,cents],...],"score":{...}?}
//   {"type":"result","total":87.5,"rank":"S","sub":{...}}
//   {"type":"clear"}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class OverlayServer extends ChangeNotifier {
  HttpServer? _server;
  final _clients = <WebSocket>{};
  Map<String, dynamic>? _lastSong;

  int get port => _server?.port ?? 0;
  bool get running => _server != null;
  int get clientCount => _clients.length;
  String get url => 'http://127.0.0.1:$port/';

  Future<void> start({int port = 0}) async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
    notifyListeners();
  }

  Future<void> stop() async {
    for (final c in _clients) {
      await c.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    notifyListeners();
  }

  void broadcast(Map<String, dynamic> msg) {
    if (msg['type'] == 'song') _lastSong = msg;
    if (msg['type'] == 'clear') _lastSong = null;
    if (_clients.isEmpty) return;
    final s = jsonEncode(msg);
    for (final c in _clients.toList()) {
      try {
        c.add(s);
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      _clients.add(ws);
      notifyListeners();
      if (_lastSong != null) ws.add(jsonEncode(_lastSong));
      ws.listen((_) {}, onDone: () {
        _clients.remove(ws);
        notifyListeners();
      }, onError: (_) {
        _clients.remove(ws);
        notifyListeners();
      });
      return;
    }
    req.response.headers.contentType = ContentType.html;
    req.response.headers.set('Cache-Control', 'no-store');
    req.response.write(_html);
    await req.response.close();
  }

  static const _html = r'''<!doctype html>
<html><head><meta charset="utf-8"><title>Karaoke Battle overlay</title>
<style>
html,body{margin:0;background:transparent;overflow:hidden;font-family:system-ui,sans-serif}
canvas{display:block}
#score{position:absolute;right:24px;top:16px;color:#fff;text-shadow:0 2px 8px #000;font-weight:700;font-size:48px}
#rank{position:absolute;right:24px;top:72px;color:#ffd54f;text-shadow:0 2px 8px #000;font-weight:800;font-size:40px}
#title{position:absolute;left:24px;top:16px;color:#fff;text-shadow:0 2px 8px #000;font-size:22px}
</style></head><body>
<canvas id="c"></canvas><div id="title"></div><div id="score"></div><div id="rank"></div>
<script>
const c=document.getElementById('c'),g=c.getContext('2d');
let notes=[],shift=0,t=0,f0=[],win=8,lead=0.3;
function resize(){c.width=innerWidth*devicePixelRatio;c.height=innerHeight*devicePixelRatio;c.style.width=innerWidth+'px';c.style.height=innerHeight+'px'}
addEventListener('resize',resize);resize();
let lo=48,hi=84;
function range(){if(!notes.length)return;let a=1e9,b=-1e9;for(const n of notes){a=Math.min(a,n.pitch);b=Math.max(b,n.pitch)}lo=Math.floor(a+shift)-3;hi=Math.ceil(b+shift)+3}
function x(time){return (lead+(time-t)/win)*c.width}
function y(p){return c.height-(p-lo)/(hi-lo)*c.height}
function draw(){
  g.clearRect(0,0,c.width,c.height);
  const h=c.height/(hi-lo);
  for(let p=lo;p<=hi;p++){g.fillStyle=([1,3,6,8,10].includes(((p%12)+12)%12))?'rgba(0,0,0,0.25)':'rgba(255,255,255,0.05)';g.fillRect(0,y(p+1),c.width,h)}
  for(const n of notes){const x0=x(n.onset),x1=x(n.offset);if(x1<0||x0>c.width)continue;const p=n.pitch+shift;g.fillStyle='rgba(90,160,255,0.85)';const r=h*0.35;g.beginPath();g.roundRect(x0,y(p)-h*0.4,Math.max(2,x1-x0),h*0.8,r);g.fill()}
  g.lineWidth=3*devicePixelRatio;
  for(let i=1;i<f0.length;i++){const a=f0[i-1],b=f0[i];if(a[1]<=0||b[1]<=0)continue;const ca=Math.abs(b[2]);g.strokeStyle=ca<=50?'#4caf50':ca<=100?'#ffeb3b':'#f44336';g.beginPath();g.moveTo(x(a[0]),y(a[1]));g.lineTo(x(b[0]),y(b[1]));g.stroke()}
  g.strokeStyle='rgba(255,255,255,0.8)';g.lineWidth=2*devicePixelRatio;g.beginPath();g.moveTo(x(t),0);g.lineTo(x(t),c.height);g.stroke();
  requestAnimationFrame(draw)}
requestAnimationFrame(draw);
function connect(){const ws=new WebSocket('ws://'+location.host+'/ws');
ws.onmessage=e=>{const m=JSON.parse(e.data);
 if(m.type==='song'){notes=m.notes||[];shift=m.shift||0;document.getElementById('title').textContent=m.title||'';f0=[];range();document.getElementById('score').textContent='';document.getElementById('rank').textContent=''}
 else if(m.type==='tick'){t=m.t;if(m.shift!==undefined&&m.shift!==shift){shift=m.shift;range()}if(m.f0){f0.push(...m.f0);const cut=t-win*lead-1;while(f0.length&&f0[0][0]<cut)f0.shift()}if(m.score)document.getElementById('score').textContent=m.score.toFixed(1)}
 else if(m.type==='result'){document.getElementById('score').textContent=m.total.toFixed(1);document.getElementById('rank').textContent=m.rank||''}
 else if(m.type==='clear'){notes=[];f0=[];document.getElementById('title').textContent=''}};
ws.onclose=()=>setTimeout(connect,1000)}
connect();
</script></body></html>''';
}
