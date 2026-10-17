// Live run dashboard: renders status.json (written by scripts/publish_live_status.py --watch).
// Used by index.html (#live section) and live.html; missing elements are skipped.
(() => {
  const $ = id => document.getElementById(id);
  const set = (id, prop, value) => { const el = $(id); if (el) el[prop] = value; };
  const fmt = n => (n ?? 0).toLocaleString();
  const fmtBytes = n => {
    if (n == null || n < 0) return '–';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / (1024 * 1024)).toFixed(1) + ' MB';
  };
  const ist = iso => iso ? new Date(iso).toLocaleString('en-IN', {timeZone: 'Asia/Kolkata', hour12: false}) : '–';
  const dur = s => { if (s == null) return '–'; const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60); return h ? `${h}h ${m}m` : `${m}m ${s % 60}s`; };
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));
  let lastPayload = null;
  let fleetFilter = '';

  const displayCell = (agents, key, phase) => {
    const a = (agents && agents[key]) || {};
    const label = phase === 'pre' ? (a.pre_display || a.pre) : (a.post_display || a.post);
    const raw = phase === 'pre' ? a.pre : a.post;
    const rep = phase === 'pre' ? a.pre_reporting : a.post_reporting;
    const title = [raw, rep].filter(Boolean).join(' · ');
    return `<td title="${esc(title)}">${displayPill(label, raw)}</td>`;
  };

  const displayPill = (label, raw) => {
    const text = label || raw || '–';
    if (!text || text === '–') return '<span class="st">–</span>';
    const cls = /active|connected|reporting|success|healthy/i.test(text) ? 'ok'
      : /not installed|disconnected|inactive|failed|unhealthy|wrong package|missing|not reporting/i.test(text) ? 'bad'
      : /pending|not checked/i.test(text) ? 'info' : 'warn';
    return `<span class="st ${cls}">${esc(text)}</span>`;
  };

  function fleetRowHtml(r) {
    const ag = r.agents || {};
    const rowCls = r.pending ? ' class="row-pending"' : '';
    const execId = r.execution_id || (lastPayload && lastPayload.report && lastPayload.report.execution_id) || '';
    return `<tr${rowCls}>
      <td><code class="exec-col" title="Execution for this row">${esc(execId || '–')}</code></td>
      <td>${esc(r.hostname)}</td>
      <td><code>${esc(r.ip)}</code></td>
      <td>${esc(r.os)}${r.os_version ? ' ' + esc(r.os_version) : ''}</td>
      <td><code>${esc(r.credential || '–')}</code></td>
      <td>${pill(r.ssh)}</td>
      ${displayCell(ag, 'tanium', 'pre')}${displayCell(ag, 'tanium', 'post')}
      ${displayCell(ag, 'sentinel', 'pre')}${displayCell(ag, 'sentinel', 'post')}
      ${displayCell(ag, 'crowdstrike', 'pre')}${displayCell(ag, 'crowdstrike', 'post')}
      ${displayCell(ag, 'rsyslog', 'pre')}${displayCell(ag, 'rsyslog', 'post')}
      ${displayCell(ag, 'azure_arc', 'pre')}${displayCell(ag, 'azure_arc', 'post')}
      <td>${pill(r.overall_pre)}</td>
      <td title="${esc(r.overall_post_raw ? 'DB post: '+r.overall_post_raw : '')}">${pill(r.overall_post)}</td>
      <td class="issues-cell" title="${esc(r.comments_audit || r.comments || r.failure_reason)}">${esc(r.comments || r.failure_reason || '–')}</td>
    </tr>`;
  }

  function fleetSearchBlob(r) {
    const ag = r.agents || {};
    const parts = [r.execution_id, r.hostname, r.ip, r.os, r.os_version, r.credential, r.ssh, r.issues_pre, r.issues_post,
      r.overall_pre, r.overall_post, r.failure_reason, r.comments];
    Object.values(ag).forEach(a => parts.push(
      a.pre, a.post, a.pre_display, a.post_display, a.pre_reporting, a.post_reporting, a.remediation_id));
    return parts.join(' ').toLowerCase();
  }

  function renderFleetTable() {
    const body = $('live-fleet-body');
    if (!body || !lastPayload) return;
    const rows = lastPayload.fleet || [];
    const q = fleetFilter.trim().toLowerCase();
    const filtered = q ? rows.filter(r => fleetSearchBlob(r).includes(q)) : rows;
    const pending = rows.filter(r => r.pending).length;
    const processed = rows.length - pending;
    set('live-fleet-count', 'textContent',
      q ? `Showing ${filtered.length} of ${rows.length} hosts` : `${rows.length} hosts (${processed} processed, ${pending} queued)`);
    body.innerHTML = filtered.map(fleetRowHtml).join('')
      || '<tr><td colspan="17">No hosts match — clear search or wait for processing</td></tr>';
  }
  const pill = s => {
    if (!s) return '<span class="st">–</span>';
    const cls = /HEALTHY|SUCCESS|AUTHENTICATED|EXECUTED/.test(s) ? 'ok'
      : /FAILED|MISSING/.test(s) ? 'bad'
      : /DRY_RUN|PENDING/.test(s) ? 'info' : 'warn';
    return `<span class="st ${cls}">${esc(s)}</span>`;
  };

  function render(d) {
    const e = d.execution;
    if (!e) { set('live-meta', 'textContent', 'No execution recorded yet.'); return; }
    const badge = $('live-badge');
    if (badge) {
      badge.textContent = `${e.id} · ${e.mode} · ${e.running ? 'RUNNING' : e.status.toUpperCase()}`;
      badge.className = 'tag ' + (e.running ? 'ok pulse' : (e.status === 'stopped' ? 'warn' : (e.mode === 'PRODUCTION' ? 'ok' : 'warn')));
    }
    if (e.id) document.title = `${e.id} · Self-healing live`;
    set('live-meta', 'textContent',
      (!e.running ? 'STOPPED: no fleet worker detected — counts frozen until a run is relaunched · ' : '')
      + `${e.id} · source ${e.source || '–'} · started ${ist(e.start_time)} IST · elapsed ${dur(e.elapsed_seconds)}`
      + (e.eta_seconds != null ? ` · ETA ${dur(e.eta_seconds)}` : '') + ` · updated ${ist(d.generated_at)}`);

    const p = d.progress, h = d.hosts, i = d.issues, s = d.ssh, o = d.outcomes || {};
    const bar = $('live-bar'); if (bar) bar.style.width = p.percent + '%';
    set('live-progtext', 'textContent', `${fmt(p.processed)} of ${fmt(p.total)} machines processed (${p.percent}%), ${fmt(p.pending)} pending`);

    const policyOther = (o.policy_other || 0) + (o.orchestrator_prerequisite || 0)
      + (o.manual_policy || 0) + (o.catalog_gap || 0);
    const kpis = {
      'k-total': p.total, 'k-processed': p.processed, 'k-ssh': s.authenticated, 'k-healthy': h.healthy_before,
      'k-active-healthy': h.healthy_now ?? d.healthy_now,
      'k-found': i.found, 'k-fixed': i.fixed, 'k-remaining': i.remaining, 'k-failed': i.actions_failed,
      'k-ssh-issues': s.issues_total ?? o.ssh_issues_total ?? ((s.auth_failed || 0) + (s.ssh_failed || 0)),
      'k-unreachable': o.ssh_unreachable ?? s.ssh_failed,
      'k-auth-failed': o.ssh_auth_failed ?? s.auth_failed,
      'k-sudo': o.sudo_blocked ?? d.hosts?.sudo_blocked ?? 0,
      'k-policy-other': policyOther,
      'k-pending': o.pending_not_processed ?? p.pending,
    };
    Object.entries(kpis).forEach(([id, n]) => set(id, 'textContent', fmt(n)));

    const rep = d.report || d.last_executed_report;
    const reportExec = (rep && rep.execution_id) || '';
    const reportUrl = (rep && rep.url) ? rep.url : (reportExec ? `downloads/${reportExec}.xlsx` : '');
    const reportName = (rep && rep.filename) || (reportExec ? `${reportExec}.xlsx` : 'execution-report.xlsx');
    const bindReportDl = (linkId, metaId, linkLabel) => {
      const dl = $(linkId);
      const repMeta = $(metaId);
      if (!dl || !repMeta) return;
      if (reportUrl) {
        dl.href = reportUrl + '?t=' + Date.now();
        dl.download = reportName;
        dl.hidden = false;
        dl.textContent = linkLabel || `Download ${reportName}`;
        const stale = rep && rep.stale ? ' (last good copy; refresh failed)' : '';
        const discovered = rep && rep.discovered_on_disk ? ' · served from on-disk copy' : '';
        const size = rep && rep.size_bytes != null ? fmtBytes(rep.size_bytes) : 'see file size after download';
        const updated = rep && rep.updated_at ? ist(rep.updated_at) : '–';
        const liveNote = rep && rep.live_execution_id
          ? ` · live run is <code>${esc(rep.live_execution_id)}</code> (Excel stays on last finished run)`
          : '';
        repMeta.innerHTML =
          `Last executed report: <code>${esc(reportExec || e.id)}</code> · ${esc(size)} · workbook updated ${esc(updated)} IST` +
          `${esc(stale)}${esc(discovered)}${liveNote}`;
      } else {
        dl.hidden = true;
        repMeta.textContent = 'Excel builds from the database as hosts are processed (refreshed with live status).';
      }
    };
    bindReportDl('live-report-dl', 'live-report-meta', reportName ? `Download ${reportName}` : null);
    bindReportDl('excel-dl', 'excel-dl-meta', reportName ? `Download last report (${reportName})` : null);

    const excelBody = $('excel-last-report-body');
    if (excelBody) {
      if (rep && reportUrl) {
        excelBody.innerHTML = `<tr>
          <td><code>${esc(reportExec)}</code></td>
          <td>${pill(rep.execution_status || '–')}</td>
          <td>${esc(rep.mode || '–')}</td>
          <td>${ist(rep.start_time)}</td>
          <td>${ist(rep.end_time)}</td>
          <td>${fmt(rep.hosts_processed)} / ${fmt(rep.hosts_total)}</td>
          <td><a href="${esc(reportUrl)}?t=${Date.now()}" download="${esc(reportName)}">${esc(reportName)}</a></td>
          <td>${esc(rep.size_bytes != null ? fmtBytes(rep.size_bytes) : '–')}</td>
          <td>${ist(rep.updated_at)}</td>
        </tr>`;
      } else {
        excelBody.innerHTML = '<tr><td colspan="9">No finished execution report yet — run completes then refresh.</td></tr>';
      }
    }

    const queued = s.queued ?? s.not_attempted ?? 0;
    const parts = [['authenticated', s.authenticated, 'ok'], ['auth failed', s.auth_failed, 'bad'],
                   ['unreachable (TCP)', s.ssh_failed, 'warn'], ['queued', queued, 'dim']];
    const tot = parts.reduce((a, x) => a + x[1], 0) || 1;
    set('live-sshbar', 'innerHTML', parts.map(([l, n, c]) =>
      n ? `<div class="seg ${c}" style="flex:${n}" title="${l}: ${n}">${n / tot > .06 ? fmt(n) : ''}</div>` : '').join(''));
    set('live-sshtable', 'innerHTML', parts.map(([l, n, c]) =>
      `<tr><td><span class="dot ${c}"></span>${l}</td><td>${fmt(n)}</td></tr>`).join(''));

    const vcNote = $('live-ssh-vcenter-note');
    if (vcNote) {
      vcNote.textContent = s.vcenter_configured
        ? 'vCenter is configured — guest IP and power state are queried for each failed host below.'
        : 'vCenter is not configured on the orchestrator — causes below are from SSH errors only. Set VCENTER_ENDPOINTS, VCENTER_USER, VCENTER_SECRET_REF in .env for VM power/guest-IP verification.';
    }
    const causes = d.ssh_unreachable || [];
    set('live-sshcause', 'innerHTML', causes.map(row =>
      `<tr><td>${esc(row.hostname)}</td><td><code>${esc(row.tanium_ip)}</code></td><td>${pill(row.ssh_status)}</td>` +
      `<td><code>${esc(row.transport_class)}</code></td><td class="issues-cell" title="${esc(row.detail)}">${esc(row.summary)}</td></tr>`
    ).join('') || '<tr><td colspan="5">No SSH/auth failures in processed hosts yet</td></tr>');

    set('live-issuetable', 'innerHTML', [
      ['— SSH & access —', ''],
      ['SSH issues total (auth failed + unreachable)', o.ssh_issues_total ?? s.issues_total],
      ['Unreachable (SSH_FAILED / TCP, route, timeout)', o.ssh_unreachable ?? s.ssh_failed],
      ['Authentication failed (SSH ok, creds rejected)', o.ssh_auth_failed ?? s.auth_failed],
      ['SSH authenticated (reached pre-check)', s.authenticated],
      ['Not processed yet (queued in this run)', o.pending_not_processed ?? p.pending],
      ['— Policy & remediation blocks —', ''],
      ['Sudo blocked (no passwordless root for automation)', o.sudo_blocked],
      ['Orchestrator missing payload/secret (prerequisite)', o.orchestrator_prerequisite],
      ['Manual / build policy (not auto-fixed in catalog)', o.manual_policy],
      ['No catalog action for agent state', o.catalog_gap],
      ['Other BLOCKED_BY_POLICY', o.policy_other],
      ['Policy blocked total', o.policy_blocked_total ?? h.blocked_by_policy],
      ['Remediation failed (Ansible ran, still unhealthy)', o.remediation_failed ?? h.remediation_failed],
      ['Unsupported OS', o.unsupported_os ?? h.unsupported_os],
      ['Other host issues (failed + policy + unsupported)', o.other_issues_total],
      ['— Agent issues —', ''],
      ['Hosts healthy at pre-check', h.healthy_before],
      ['Hosts needing remediation', h.needs_remediation],
      ['Agent issues found (per agent × host, not machine count)', i.found],
      ['Agent issues fixed (healthy or sensor active)', i.fixed],
      ['Agent issues still open', i.remaining],
      ['Hosts remediated to HEALTHY', i.hosts_remediated_to_healthy ?? '—'],
      ['Remediation actions executed', i.actions_executed],
      ['Remediation actions failed', i.actions_failed],
      ['Actions planned only (dry-run)', i.actions_planned],
      ['Hosts blocked by policy (no sudo / no catalog fix)', h.blocked_by_policy],
      ['Hosts remediated successfully', h.remediated_success],
      ['Hosts healthy now', h.healthy_now],
    ].map(([l, n]) => (String(l).startsWith('—')
      ? `<tr class="section-row"><td colspan="2"><b>${esc(l)}</b></td></tr>`
      : `<tr><td>${l}</td><td>${fmt(n ?? 0)}</td></tr>`)).join(''));

    set('live-agenttable', 'innerHTML', Object.entries(d.agents).map(([name, a]) =>
      `<tr><td><b>${esc(name)}</b></td><td>${fmt(a.pre.HEALTHY)}</td><td>${fmt(a.issues)}</td><td>${fmt(a.fixed)}</td>
       <td>${Object.entries(a.pre).filter(([k]) => k !== 'HEALTHY').map(([k, n]) => `${pill(k)} ${n}`).join(' ') || '–'}</td></tr>`
    ).join('') || '<tr><td colspan="5">No hosts checked yet</td></tr>');

    set('live-actiontable', 'innerHTML', Object.entries(d.actions).map(([name, c]) =>
      `<tr><td><code>${esc(name)}</code></td><td>${fmt(c.EXECUTED)}</td><td>${fmt(c.REMEDIATION_FAILED)}</td><td>${fmt(c.DRY_RUN)}</td><td>${fmt(c.BLOCKED_BY_POLICY)}</td></tr>`
    ).join('') || '<tr><td colspan="5">No remediation actions yet</td></tr>');

    set('live-recenttable', 'innerHTML', d.recent.map(r =>
      `<tr><td>${esc(r.hostname)}</td><td><code>${esc(r.ip)}</code></td><td>${pill(r.ssh)}</td><td>${pill(r.pre)}</td><td>${pill(r.post)}</td><td>${esc(r.credential || '–')}</td><td>${ist(r.time)}</td></tr>`
    ).join('') || '<tr><td colspan="7">No hosts processed yet</td></tr>');

    set('live-failtable', 'innerHTML', d.top_failures.map(f =>
      `<tr><td>${esc(f.reason)}</td><td>${fmt(f.count)}</td></tr>`).join('') || '<tr><td colspan="2">None</td></tr>');

    renderAnomaly(d.anomaly_execution);
    lastPayload = d;
    renderFleetTable();
  }

  function renderAnomaly(a) {
    if (!a || !a.progress) {
      set('anomaly-meta', 'textContent', 'No anomaly plan on disk yet — copy linux servers anomalies.csv to reports/drop/ and run run_tanium_anomalies_csv.py --plan-only.');
      return;
    }
    const badge = $('anomaly-badge');
    if (badge) {
      let label = a.status || 'MONITORING';
      if (a.running) label = 'RUNNING';
      else if (a.fleet_remediate_active) label = 'WAITING (fleet lock)';
      badge.textContent = `${a.execution_id || ''} · ${label}`;
      badge.className = 'tag ' + (a.running ? 'ok pulse' : (a.fleet_remediate_active ? 'warn' : 'ok'));
    }
    const p = a.progress;
    const o = a.outcomes || {};
    const bar = $('anomaly-bar');
    if (bar) bar.style.width = (p.percent || 0) + '%';
    set('anomaly-progtext', 'textContent',
      `${fmt(p.processed)} of ${fmt(p.total)} anomaly hosts have execution rows (${p.percent}%), ${fmt(p.pending)} not processed yet`
      + (a.eta_seconds != null ? ` · ETA ${dur(a.eta_seconds)}` : ''));
    const waitNote = a.fleet_remediate_active
      ? ' · Another fleet worker holds the lock — dedicated anomaly production starts after it exits.'
      : (a.running ? ' · Anomaly CSV production is running now.' : ' · Run run_tanium_anomalies_csv.py --production when the fleet lock is free.');
    set('anomaly-meta', 'textContent',
      `Source ${a.source_csv || '–'} · plan ${a.plan_csv || '–'} · non-Stryker enforce ${fmt(a.non_stryker_enforce_rows)}${waitNote}`);
    const kpis = {
      'ka-total': p.total,
      'ka-processed': p.processed,
      'ka-healthy': o.healthy_post,
      'ka-improved': o.improved_to_compliant,
      'ka-pending': p.pending,
      'ka-failed': o.remediation_failed,
      'ka-non-stryker': a.non_stryker_enforce_rows,
      'ka-blocked': o.blocked_by_policy,
    };
    Object.entries(kpis).forEach(([id, n]) => set(id, 'textContent', fmt(n)));
    const planDl = $('anomaly-plan-dl');
    const planMeta = $('anomaly-plan-meta');
    if (planDl && planMeta && a.plan_url) {
      planDl.href = a.plan_url + '?t=' + Date.now();
      planDl.download = a.plan_csv || 'anomaly-plan.csv';
      planDl.hidden = false;
      planMeta.textContent = `Remediation plan exported from CSV hints (${a.plan_csv}).`;
    } else if (planMeta) {
      planMeta.textContent = 'Generate plan: python3 scripts/run_tanium_anomalies_csv.py EXEC-2026-10-05-002 --plan-only';
    }
    const moves = a.movements_recent || [];
    set('anomaly-movements-body', 'innerHTML', moves.map(m =>
      `<tr><td>${esc(m.hostname)}</td><td><code>${esc(m.ip)}</code></td><td><code>${esc(m.planned_actions)}</code></td>` +
      `<td>${pill(m.overall_pre)}</td><td>${pill(m.overall_post)}</td>` +
      `<td>${esc(m.tanium || '–')}</td><td>${esc(m.crowdstrike || '–')}</td>` +
      `<td>${esc(m.azure_arc || '–')}</td><td>${esc(m.rsyslog || '–')}</td>` +
      `<td class="issues-cell">${esc(m.movement_summary)}</td><td>${ist(m.updated_at)}</td></tr>`
    ).join('') || '<tr><td colspan="11">No movements recorded yet — start the anomaly production pass or wait for fleet remediation on these hosts.</td></tr>');
    const planned = a.planned_actions || {};
    set('anomaly-planned-body', 'innerHTML', Object.entries(planned).sort((x, y) => y[1] - x[1]).map(([name, n]) =>
      `<tr><td><code>${esc(name)}</code></td><td>${fmt(n)}</td></tr>`
    ).join('') || '<tr><td colspan="2">No plan file</td></tr>');
    const actions = a.remediation_actions || {};
    set('anomaly-actions-body', 'innerHTML', Object.entries(actions).map(([name, c]) =>
      `<tr><td><code>${esc(name)}</code></td><td>${fmt(c.EXECUTED)}</td><td>${fmt(c.REMEDIATION_FAILED)}</td><td>${fmt(c.BLOCKED_BY_POLICY)}</td></tr>`
    ).join('') || '<tr><td colspan="4">No Ansible actions on anomaly hosts in this execution yet</td></tr>');
  }

  let pollTimer = null;
  function scheduleRefresh(seconds) {
    const sec = Math.max(3, Math.min(60, Number(seconds) || 5));
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = setTimeout(tick, sec * 1000);
  }

  async function tick() {
    let nextSec = 5;
    try {
      const r = await fetch('status.json?t=' + Date.now(), {cache: 'no-store'});
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const data = await r.json();
      lastPayload = data;
      render(data);
      const ex = data.execution || {};
      nextSec = ex.live_refresh_seconds || (ex.running ? 5 : 10);
      const note = $('live-refresh-note');
      if (note) {
        note.innerHTML = `Live data from <code>status.json</code> — browser polls every ${nextSec} s`
          + (ex.running ? ' (<strong>RUNNING</strong>)' : ' (idle)')
          + `; publisher <code>publish_live_status.py --watch</code> uses the same cadence. Overall post = dashboard view; Excel Comments = audit detail. Full-screen: <a href="live.html">live.html</a>.`;
      }
    } catch (err) {
      set('live-meta', 'textContent', `status.json not available (${err.message}) — run: bash scripts/ensure_live_publisher.sh`);
      nextSec = 5;
    }
    scheduleRefresh(nextSec);
  }
  const searchEl = $('live-fleet-search');
  if (searchEl) {
    searchEl.addEventListener('input', () => {
      fleetFilter = searchEl.value;
      renderFleetTable();
    });
  }
  tick();
})();
