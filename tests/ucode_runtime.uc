// SPDX-License-Identifier: MIT
// Executed by the real OpenWrt /usr/bin/ucode in the QEMU guest.
// Fails if daemon.ubus integration or the installed ucode modules do not work.
import * as ubus from 'ubus';
import * as uloop from 'uloop';
import { cursor } from 'uci';

if (!uloop.init())
    die('FAIL: uloop.init()\n');

const cfg = cursor();
if (cfg.get('parallax', 'main', 'enabled') != '1')
    die('FAIL: UCI parallax.main.enabled must be 1\n');

const conn = ubus.connect();
if (!conn)
    die('FAIL: ubus.connect()\n');

const s = conn.call('parallax', 'status', {});
if (!s || s.name != 'parallax' || s.phase != 'mvp-b' ||
    s.version != '0.3.0' || s.daemon_running != true || s.routing_active != false ||
    s.proxy_running != false || s.config_enabled != true)
    die('FAIL: invalid ubus status\n');

const p = conn.call('parallax', 'ping', {});
if (!p || p.ok != true || p.name != 'parallax')
    die('FAIL: ubus ping\n');

printf('PASS: real ucode + uloop + uci + ubus status and ping; heartbeat=%d\n', s.heartbeat_seq);
conn.disconnect();
