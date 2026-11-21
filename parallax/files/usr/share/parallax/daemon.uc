// SPDX-License-Identifier: MIT
// Parallax MVP (b): safe event-driven status service skeleton.
// No sing-box process, routing, DNS or firewall mutations are performed here.

import * as uloop from 'uloop';
import * as ubus from 'ubus';
import { cursor } from 'uci';
import { glob, readfile } from 'fs';

const VERSION = '0.4.0';

// Read-only process discovery; never change native sing-box or kernel state.
function isolatedSingbox() {
    let expected = null;
    let passwd = readfile('/etc/passwd') ?? '';
    for (let line in split(passwd, '\n')) {
        let fields = split(line, ':');
        if (fields[0] == 'parallax-sb') expected = fields[2];
    }
    for (let path in glob('/proc/[0-9]*/cmdline') ?? []) {
        let cmd = readfile(path, 4096) ?? '';
        if (index(cmd, '/usr/bin/sing-box') < 0 ||
            index(cmd, '/run/parallax-singbox/config.json') < 0) continue;
        let m = match(path, /^\/proc\/([0-9]+)\/cmdline$/);
        if (!m) continue;
        let procstatus = readfile('/proc/' + m[1] + '/status', 8192) ?? '';
        let uid = match(procstatus, /Uid:[ \t]*([0-9]+)/);
        if (!uid || expected == null || uid[1] != expected) continue;
        return { running: true, pid: +m[1], user: 'parallax-sb' };
    }
    return { running: false, pid: null, user: 'parallax-sb' };
}

let heartbeat_seq = 0;

function status() {
    const cfg = cursor();
    const enabled = cfg.get('parallax', 'main', 'enabled');
    const schema = cfg.get('parallax', 'main', 'schema_version');

    return {
        name: 'parallax',
        version: VERSION,
        phase: 'mvp-c2a-0',
        // Isolated sing-box process state is NOT traffic-interception readiness.
        interception_supported: false,
        interception_ready: false,
        interception_active: false,
        net_enable_available: false,
        network_preflight_only: true,
        daemon_running: true,
        routing_active: false,
        proxy_running: isolatedSingbox().running,
        singbox: isolatedSingbox(),
        config_enabled: enabled == '1',
        schema_version: schema,
        heartbeat_seq: heartbeat_seq
    };
}

if (!uloop.init())
    die('Parallax: cannot initialize uloop\n');

const connection = ubus.connect();
if (!connection)
    die('Parallax: cannot connect to ubus\n');

const published = connection.publish('parallax', {
    status: {
        // uhttpd-mod-ubus injects ubus_rpc_session into HTTP /ubus calls.
        // The native ucode ubus method validator rejects undeclared arguments.
        // Declare this transport-only string; handlers remain read-only.
        args: { ubus_rpc_session: '' },
        call: (req, msg) => req.reply(status())
    },
    ping: {
        // uhttpd-mod-ubus injects ubus_rpc_session into HTTP /ubus calls.
        // The native ucode ubus method validator rejects undeclared arguments.
        // Declare this transport-only string; handlers remain read-only.
        args: { ubus_rpc_session: '' },
        call: (req, msg) => req.reply({ ok: true, name: 'parallax', phase: 'mvp-c2a-0' })
    }
});
if (!published)
    die('Parallax: cannot publish ubus object\n');

const heartbeat = uloop.interval(10000, () => heartbeat_seq++);
if (!heartbeat)
    die('Parallax: cannot initialize heartbeat\n');

printf('Parallax %s (MVP-c2a-0) started: interception unavailable, routing disabled\n', VERSION);
const result = uloop.run();
connection.disconnect();
if (result == null)
    die('Parallax: event loop failed\n');
