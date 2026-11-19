(async () => {
  const grant = new URLSearchParams(location.hash.slice(1)).get('grant');
  history.replaceState(null, '', location.pathname);
  try {
    if (!grant || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(grant)) throw Error();
    const r = await fetch('/vas/redeem', {
      method: 'POST', cache: 'no-store',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({grant})
    });
    if (!r.ok) throw Error();
    const {url} = await r.json();
    if (!/^\/vas\/\?room=[a-f0-9]{32}#jwt=[A-Za-z0-9_.-]+$/.test(url)) throw Error();
    location.replace(url);
  } catch (_) {
    document.getElementById('state').textContent='Die OpsLinX-Freigabe ist ungültig oder abgelaufen. Bitte die Video-Hilfe aus OpsLinX erneut öffnen.';
  }
})();
