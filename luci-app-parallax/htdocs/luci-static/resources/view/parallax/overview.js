'use strict';
'require view';
'require rpc';
'require poll';

const callStatus = rpc.declare({
    object: 'parallax',
    method: 'status',
    expect: { '': {} }
});

function renderStatus(node, state) {
    if (!state || !state.daemon_running) {
        node.textContent = _('Service is stopped or unavailable');
        return;
    }

    node.textContent = [
        _('Daemon: running'),
        _('Version: ') + (state.version || '?'),
        _('Phase: ') + (state.phase || '?'),
        _('Heartbeat: ') + (state.heartbeat_seq != null ? state.heartbeat_seq : 0),
        _('Routing: disabled — preflight only'),
        _('Traffic interception: unavailable (no net enable / TProxy)'),
        _('Isolated sing-box process: ') + (state.singbox && state.singbox.running ? _('running (not interception)') : _('stopped'))
    ].join('\n');
}

return view.extend({
    load: function() {
        return callStatus().catch(() => null);
    },

    render: function(initialState) {
        const status = E('pre', { 'class': 'cbi-section' });
        renderStatus(status, initialState);

        poll.add(() => callStatus().then(data => {
            renderStatus(status, data);
        }).catch(() => renderStatus(status, null)), 5);

        return E('div', {}, [
            E('h2', {}, _('Parallax')),
            E('div', { 'class': 'alert-message warning' },
                _('MVP-c2a-0 supports read-only preflight only. Traffic interception is unavailable; no routing, DNS or firewall changes are made.')),
            E('p', {}, _('Enable the status service from SSH after validating the platform and configuration.')),
            status
        ]);
    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
