// SPDX-License-Identifier: MIT
// Strictly validated output contains only non-secret identifiers.
import { cursor } from 'uci';
import { inspectSelected } from './selected_clients.uc';
let sections = cursor().get_all('parallax');
let cmd = ARGV[0] ?? 'validate';
if (cmd != 'validate' && cmd != 'one')
    die('parallax-selected: unsupported command\n');
let selected = inspectSelected(sections, cmd == 'one' ? 1 : null);
if (cmd == 'one') {
    let c = selected[0];
    printf('%s\t%s\t%s\t%s\t%s\n',
        c.name, c.mac, c.ipv4, c.interface, c.binding_proof);
}
