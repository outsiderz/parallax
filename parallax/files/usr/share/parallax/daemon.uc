// SPDX-License-Identifier: MIT
// Parallax MVP (a): safe event-driven service skeleton.
// No sing-box process, routing, DNS or firewall mutations are performed here.

import * as uloop from 'uloop';
import * as ubus from 'ubus';
import { cursor } from 'uci';

const VERSION = '0.1.0';
let heartbeat_seq = 0;

function status() {
    const cfg = cursor();
    const enabled = cfg.get('parallax', 'main', 'enabled');
    const schema = cfg.get('parallax', 'main', 'schema_version');

    return {
        name: 'parallax',
        version: VERSION,
        phase: 'mvp-a',
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
        call: (req, msg) => req.reply(status())
    },
    ping: {
        call: (req, msg) => req.reply({ ok: true, name: 'parallax', phase: 'mvp-a' })
    }
});
if (!published)
    die('Parallax: cannot publish ubus object\n');

const heartbeat = uloop.interval(10000, () => heartbeat_seq++);
if (!heartbeat)
    die('Parallax: cannot initialize heartbeat\n');

printf('Parallax %s (MVP-a) started: routing disabled\n', VERSION);
const result = uloop.run();
connection.disconnect();
if (result == null)
    die('Parallax: event loop failed\n');
