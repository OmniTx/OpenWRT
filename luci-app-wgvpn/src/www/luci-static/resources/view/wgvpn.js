'use strict';
'require view';
'require rpc';
'require uci';
'require form';
'require ui';

var callStatus = rpc.declare({
    object: 'luci.wgvpn',
    method: 'status',
    expect: {}
});

var callApply = rpc.declare({
    object: 'luci.wgvpn',
    method: 'apply',
    expect: {}
});

return view.extend({
    pollInterval: 5,

    load: function () {
        return Promise.all([
            L.resolveDefault(callStatus(), {}),
            uci.load('wgvpn')
        ]);
    },

    render: function (data) {
        var st = data[0] || {};
        var ok = (st.handshake || '').indexOf('ago') !== -1;
        var clr = ok ? '#22c55e' : '#ef4444';

        var card = E('div', { 'class': 'wg-card' }, [
            E('style', {}, [
                '.wg-card{background:linear-gradient(135deg,#0f172a 0%,#1e293b 100%);',
                'border-radius:14px;padding:20px 24px;margin-bottom:22px;',
                'border:1px solid #334155;box-shadow:0 4px 24px rgba(0,0,0,.4);}',
                '.wg-title{display:flex;align-items:center;gap:10px;margin-bottom:18px;}',
                '.wg-dot{width:12px;height:12px;border-radius:50%;',
                'background:' + clr + ';box-shadow:0 0 8px ' + clr + ';',
                'animation:wgblink 2s ease-in-out infinite;}',
                '@keyframes wgblink{0%,100%{opacity:1}50%{opacity:.3}}',
                '.wg-label{font-size:18px;font-weight:700;color:#f1f5f9;}',
                '.wg-badge{margin-left:auto;font-size:12px;font-weight:600;',
                'padding:3px 10px;border-radius:20px;',
                'background:' + (ok ? 'rgba(34,197,94,.15)' : 'rgba(239,68,68,.15)') + ';',
                'color:' + clr + ';}',
                '.wg-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;}',
                '.wg-stat{background:rgba(15,23,42,.6);border-radius:10px;padding:12px 14px;}',
                '.wg-stat-label{font-size:11px;text-transform:uppercase;letter-spacing:.05em;',
                'color:#64748b;margin-bottom:6px;}',
                '.wg-stat-value{font-size:14px;font-weight:600;word-break:break-all;}',
                '@media(max-width:480px){.wg-grid{grid-template-columns:1fr 1fr;}}',
            ].join('')),
            E('div', { 'class': 'wg-title' }, [
                E('div', { 'class': 'wg-dot' }),
                E('span', { 'class': 'wg-label' }, _('WireGuard VPN')),
                E('span', { 'class': 'wg-badge' }, ok ? _('CONNECTED') : _('DISCONNECTED'))
            ]),
            E('div', { 'class': 'wg-grid' }, [
                E('div', { 'class': 'wg-stat' }, [
                    E('div', { 'class': 'wg-stat-label' }, _('Endpoint')),
                    E('div', { 'class': 'wg-stat-value', style: 'color:#38bdf8' }, st.endpoint || '—')
                ]),
                E('div', { 'class': 'wg-stat' }, [
                    E('div', { 'class': 'wg-stat-label' }, _('Last Handshake')),
                    E('div', { 'class': 'wg-stat-value', style: 'color:' + clr }, st.handshake || '—')
                ]),
                E('div', { 'class': 'wg-stat' }, [
                    E('div', { 'class': 'wg-stat-label' }, _('Data Transfer')),
                    E('div', { 'class': 'wg-stat-value', style: 'color:#a78bfa' }, st.transfer || '—')
                ]),
                E('div', { 'class': 'wg-stat' }, [
                    E('div', { 'class': 'wg-stat-label' }, _('Active Rules')),
                    E('div', { 'class': 'wg-stat-value', style: 'color:#fbbf24;font-size:20px' }, String(st.rules || 0))
                ])
            ])
        ]);

        var m = new form.Map('wgvpn', _('WireGuard VPN Manager'),
            _('Control which devices route through the VPN tunnel. Click Save & Apply after changes.'));

        var sg = m.section(form.TypedSection, 'global', _('Settings'));
        sg.anonymous = true;
        sg.addremove = false;

        var oiface = sg.option(form.Value, 'interface', _('WireGuard Interface'),
            _('System name of your WireGuard interface — must match Network > Interfaces (e.g. wg_vpn).'));
        oiface.placeholder = 'wg_vpn';
        oiface.rmempty = false;
        oiface.validate = function (sid, val) {
            return /^[a-zA-Z0-9_-]+$/.test(val) || _('Letters, numbers, underscores and dashes only.');
        };

        var otable = sg.option(form.Value, 'table', _('Routing Table ID'),
            _('Numeric ID of the VPN routing table. Default 100; change only if it conflicts with another service.'));
        otable.placeholder = '100';
        otable.datatype = 'uinteger';
        otable.rmempty = false;

        var omode = sg.option(form.ListValue, 'mode', _('VPN Mode'));
        omode.value('selective', _('🎯  Selective — route only listed IPs / subnets'));
        omode.value('all', _('🌐  All — route every connected LAN through VPN'));
        omode.rmempty = false;

        var oipv6 = sg.option(form.Flag, 'block_ipv6', _('🛡️  Block IPv6 leaks'),
            _('Drops global-scope IPv6 from the VPN bridge so devices cannot bypass the tunnel.'));
        oipv6.rmempty = false;

        var obr = sg.option(form.Value, 'lan_bridge', _('VPN LAN Bridge'),
            _('Bridge used for IPv6 leak blocking. br-lan for single-LAN setups; br-vpn_lan if VPN clients are on a separate bridge.'));
        obr.placeholder = 'br-lan';
        obr.optional = true;
        obr.validate = function (sid, val) {
            return !val || /^[a-zA-Z0-9_-]+$/.test(val) || _('Letters, numbers, underscores and dashes only.');
        };

        var odns = sg.option(form.Value, 'vpn_dns', _('VPN DNS Server'),
            _('DNS reachable through the tunnel (e.g. 10.2.0.1 for Proton VPN). Leave blank to keep the system default.'));
        odns.placeholder = '10.2.0.1';
        odns.optional = true;
        odns.datatype = 'ip4addr';

        var sr = m.section(form.TableSection, 'rule', _('Routing Rules'),
            _('Selective mode only. Each active rule sends matching traffic through the VPN.'));
        sr.anonymous = false;
        sr.addremove = true;
        sr.sortable = false;

        var oname = sr.option(form.Value, 'name', _('Label'));
        oname.placeholder = _('My PC');
        oname.width = '25%';

        var osubnet = sr.option(form.Value, 'subnet', _('IP / Subnet'));
        osubnet.placeholder = '192.168.15.50';
        osubnet.width = '40%';
        osubnet.validate = function (sid, val) {
            if (!val) return true;
            return /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/.test(val) ||
                _('Enter a valid IP or subnet (e.g. 192.168.15.50 or 192.168.15.0/24)');
        };

        var oen = sr.option(form.Flag, 'enabled', _('Active'));
        oen.rmempty = false;
        oen.width = '15%';

        return m.render().then(function (formEl) {
            return E('div', {}, [card, formEl]);
        });
    },

    handleSaveApply: function (ev) {
        return this.handleSave(ev).then(function () {
            ui.showModal(_('Applying…'), [
                E('p', { 'class': 'spinning' }, _('Updating routing rules and firewall, please wait…'))
            ]);
            return L.resolveDefault(callApply(), {}).then(function (res) {
                ui.hideModal();
                if (res && res.result === 'error') {
                    ui.addNotification(null, E('p', _('❌ ') + res.message), 'error');
                } else {
                    ui.addNotification(null, E('p', _('✅ VPN rules applied successfully!')), 'info');
                }
            }).catch(function (e) {
                ui.hideModal();
                ui.addNotification(null, E('p', _('❌ Apply failed: ') + (e.message || e)), 'error');
            });
        });
    }
});