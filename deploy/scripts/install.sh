<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
<html>
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
  <meta http-equiv="Content-Style-Type" content="text/css">
  <title></title>
  <meta name="Generator" content="Cocoa HTML Writer">
  <meta name="CocoaVersion" content="2575.7">
  <style type="text/css">
    p.p1 {margin: 0.0px 0.0px 0.0px 0.0px; font: 12.0px Times; -webkit-text-stroke: #000000}
    p.p2 {margin: 0.0px 0.0px 0.0px 0.0px; font: 12.0px Times; -webkit-text-stroke: #000000; min-height: 14.0px}
    span.s1 {font-kerning: none}
  </style>
</head>
<body>
<p class="p1"><span class="s1">#!/usr/bin/env bash</span></p>
<p class="p1"><span class="s1">set -e</span></p>
<p class="p2"><span class="s1"></span><br></p>
<p class="p1"><span class="s1">APP_DIR=/opt/metalgpt</span></p>
<p class="p1"><span class="s1">useradd -r -s /usr/sbin/nologin metalgpt || true</span></p>
<p class="p2"><span class="s1"></span><br></p>
<p class="p1"><span class="s1">apt update</span></p>
<p class="p1"><span class="s1">apt install -y nginx python3-venv docker.io docker-compose-plugin</span></p>
<p class="p2"><span class="s1"></span><br></p>
<p class="p1"><span class="s1">mkdir -p $APP_DIR</span></p>
<p class="p1"><span class="s1">python3 -m venv $APP_DIR/venv</span></p>
<p class="p1"><span class="s1">$APP_DIR/venv/bin/pip install -U pip vllm -r backend/requirements.txt</span></p>
<p class="p2"><span class="s1"></span><br></p>
<p class="p1"><span class="s1">docker compose -f deploy/docker-compose.redis.yml up -d</span></p>
<p class="p2"><span class="s1"></span><br></p>
<p class="p1"><span class="s1">cp deploy/systemd/*.service /etc/systemd/system/</span></p>
<p class="p1"><span class="s1">systemctl daemon-reload</span></p>
<p class="p1"><span class="s1">systemctl enable --now metalgpt-vllm metalgpt-web</span></p>
<p class="p2"><span class="s1"></span><br></p>
<p class="p1"><span class="s1">cp deploy/nginx/metalgpt.conf /etc/nginx/sites-available/metalgpt.conf</span></p>
<p class="p1"><span class="s1">ln -sf /etc/nginx/sites-available/metalgpt.conf /etc/nginx/sites-enabled/</span></p>
<p class="p1"><span class="s1">nginx -t &amp;&amp; systemctl reload nginx</span></p>
</body>
</html>
