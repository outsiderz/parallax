// SPDX-License-Identifier: MIT
// Parallax MVP (b): safe event-driven status service skeleton.
// No sing-box process, routing, DNS or firewall mutations are performed here.

import * as uloop from 'uloop';
import * as ubus from 'ubus';
import { cursor } from 'uci';

const VERSION = '0.2.0';
let heartbeat_seq = 0;

function status() {
    const cfg = cursor();
    const enabled = cfg.get('parallax', 'main', 'enabled');
    const schema = cfg.get('parallax', 'main', 'schema_version');

    return {
        name: 'parallax',
        version: VERSION,
        phase: 'mvp-b',
        daemon_running: true,
        routing_active: false,
        proxy_running: false,
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
        call: (req, msg) => req.reply({ ok: true, name: 'parallax', phase: 'mvp-b' })
    }
});
if (!published)
    die('Parallax: cannot publish ubus object\n');

const heartbeat = uloop.interval(10000, () => heartbeat_seq++);
if (!heartbeat)
    die('Parallax: cannot initialize heartbeat\n');

printf('Parallax %s (MVP-b) started: routing disabled\n', VERSION);
const result = uloop.run();
connection.disconnect();
if (result == null)
    die('Parallax: event loop failed\n');
