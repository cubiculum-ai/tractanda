// Playwright CLI run-code fixture. Replace __FIXTURE_TOKEN__ with a disposable server's
// launch token before running; never use a real user's password. Only /auth/login is
// simulated. Item reads/writes, retry replay and logout use the actual local servers.
async (page) => {
  const token = '__FIXTURE_TOKEN__';
  // Accept leaving the disposable page automatically. Keep the real retry journal
  // and reload behavior, but omit the browser's unsaved-edit confirmation in this test.
  await page.addInitScript(() => {
    const addListener = window.addEventListener.bind(window);
    window.addEventListener = (type, ...argumentsList) => {
      if (type !== 'beforeunload') addListener(type, ...argumentsList);
    };
  });
  await page.goto('__FIXTURE_URL__');
  const origin = await page.evaluate(() => location.origin);
  const checks = [], errors = [];
  const check = (condition, label) => { if (!condition) throw new Error(label); checks.push(label); };
  check(await page.evaluate(async () => !!navigator.brave && await navigator.brave.isBrave()), 'Browser verification runs in Brave');
  page.on('pageerror', error => errors.push(error.message));
  page.on('dialog', dialog => dialog.accept());
  const profile = await (await page.request.get(origin + '/auth/session')).json();
  const headers = {'Content-Type':'application/json', Authorization:'Bearer '+token};
  async function rpc(method, values) {
    const response = await page.request.post(origin+'/api', {headers, data:{using:['https://tractanda.ai/ns/local-prototype/2'],methodCalls:[[method, values, 'ui-test']]}});
    if (response.status() !== 200) throw new Error('Native API failed: '+response.status());
    const call = (await response.json()).methodResponses[0];
    if (call[0] !== method) throw new Error('Native method failed: '+JSON.stringify(call));
    return call[1];
  }
  await page.route('**/auth/login', async route => {
    const fields = route.request().postDataJSON();
    const accepted = fields.username === profile.username && fields.password === 'fixture-password';
    await route.fulfill({status:accepted?200:401, contentType:'application/json', body:JSON.stringify(accepted
      ? {token, username:profile.username, expiresAt:new Date(Date.now()+3600000).toISOString()}
      : {code:'invalidCredentials', message:'Sign-in failed. Check the account name and password.'})});
  });
  await page.evaluate(() => {localStorage.clear();sessionStorage.clear();});
  await page.reload();
  await page.locator('#login-username').waitFor({state:'visible'});
  await page.waitForFunction(() => document.querySelector('#login-username').value !== '');
  check(await page.locator('#login-password').isVisible(), 'Plain URL shows sign-in instead of an empty board');
  check(await page.locator('#login-username').inputValue() === profile.username, 'OS account name is prefilled');
  await page.setViewportSize({width:1280,height:900});
  await page.screenshot({path:'output/playwright/login-desktop.png',fullPage:true});
  await page.setViewportSize({width:390,height:844});
  check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Mobile sign-in fits without horizontal scrolling');
  await page.screenshot({path:'output/playwright/login-mobile.png',fullPage:true});
  await page.setViewportSize({width:1440,height:1000});
  await page.locator('#login-password').fill('wrong-fixture-password');
  await page.locator('#show-password').click();
  check(await page.locator('#login-password').getAttribute('type') === 'text', 'Password visibility toggle works');
  await page.locator('#sign-in').click();
  await page.waitForFunction(() => document.querySelector('#login-message').textContent.includes('Sign-in failed'));
  check(await page.locator('#login-password').inputValue() === '', 'Failed sign-in clears the password');
  check(await page.locator('#login-password').getAttribute('type') === 'password', 'Failed sign-in restores password masking');
  await page.locator('#login-password').fill('fixture-password');
  await page.locator('#sign-in').click();
  await page.locator('.card-title').first().waitFor();
  check(await page.locator('.card-title').count() === 2, 'Successful sign-in loads the actual native board');
  check(await page.evaluate(() => !!localStorage.getItem('tractanda.browser-session')), 'Remembered sign-in stores an origin-scoped session');
  check(await page.evaluate(() => location.hash === ''), 'Working page URL contains no session token');
  const second = await page.context().newPage();
  await second.goto(origin);
  await second.locator('.card-title').first().waitFor();
  check(await second.locator('.card-title').count() === 2, 'Another tab opens the board without a launch link');

  const firstID = (await rpc('TractandaItem/query',{expression:'subject == "HTTP test first"'})).ids[0];
  const before = await rpc('TractandaItem/history',{itemID:firstID});
  const operations = [];
  let replayed = false;
  await page.route('**/api', async route => {
    const call = route.request().postDataJSON().methodCalls[0];
    if (call[0] !== 'TractandaItem/commit') {await route.continue();return;}
    operations.push(call[1].operationID);
    const response = await route.fetch();
    const result = (await response.json()).methodResponses[0];
    if (result[0] !== call[0]) throw new Error('Fixture commit failed');
    if (operations.length === 1) {
      await route.fulfill({status:401, contentType:'application/json', body:JSON.stringify({code:'unauthorized',message:'Session expired during fixture response loss.'})});
    } else {replayed = result[1].replayed;await route.fulfill({response});}
  });
  await page.getByRole('button',{name:'HTTP test first',exact:true}).click();
  await page.locator('#edit-title').fill('Login retry preserved');
  await page.locator('#task-form [type=submit]').click();
  await page.locator('#login-password').waitFor({state:'visible'});
  check(await page.evaluate(() => Object.keys(sessionStorage).some(key => key.startsWith('tractanda.pending.'))), 'Authentication loss retains the exact pending edit');
  await page.reload();
  await page.locator('#login-password').waitFor({state:'visible'});
  await page.locator('#login-password').fill('fixture-password');
  await page.locator('#sign-in').click();
  await page.locator('#retry-write').waitFor({state:'visible'});
  await page.locator('#sign-out').click();
  check(await page.locator('#retry-write').isVisible(), 'Sign-out refuses to discard an unresolved edit');
  await page.locator('#retry-write').click();
  await page.locator('#retry-write').waitFor({state:'hidden'});
  await page.waitForFunction(() => !Object.keys(sessionStorage).some(key => key.startsWith('tractanda.pending.')));
  check(operations.length === 2 && operations[0] === operations[1] && replayed, 'Re-authentication and reload retry the original operation successfully');
  const after = await rpc('TractandaItem/history',{itemID:firstID});
  check(after.total === before.total+1, 'A committed but unconfirmed edit creates exactly one revision');
  check(await page.evaluate(() => !Object.keys(sessionStorage).some(key => key.startsWith('tractanda.pending.'))), 'Confirmed retry clears its browser journal');
  await page.getByRole('button',{name:'Login retry preserved',exact:true}).waitFor();
  const downloadPromise = page.waitForEvent('download');
  await page.locator('#save-html').click();
  const download = await downloadPromise;
  await download.saveAs('output/playwright/login-export.html');
  const snapshot = await page.context().newPage();
  await snapshot.goto('__EXPORT_URL__');
  await snapshot.getByRole('button',{name:'Login retry preserved',exact:true}).waitFor();
  check(!await snapshot.locator('#login-password').isVisible(), 'HTML export opens offline as a board without login');
  const html = await snapshot.content();
  check(!html.includes(token) && !html.includes('fixture-password'), 'HTML export contains no session or password');
  await snapshot.close();
  await page.locator('#sign-out').click();
  await page.locator('#login-password').waitFor({state:'visible'});
  await second.locator('#login-password').waitFor({state:'visible'});
  check(!await page.evaluate(() => localStorage.getItem('tractanda.browser-session') || sessionStorage.getItem('tractanda.web-session')), 'Sign-out removes stored browser credentials');
  check(await second.locator('#login-password').isVisible(), 'Other tabs sharing that browser session return to sign-in');
  const revoked = await page.request.post(origin+'/api',{headers,data:{using:['https://tractanda.ai/ns/local-prototype/2'],methodCalls:[['TractandaStore/info',{},'revoked']]}});
  check(revoked.status() === 401, 'Actual server logout rejects subsequent use of the old token');
  check(errors.length === 0, 'No browser JavaScript errors');
  await second.close();
  const result = {status:'passed',count:checks.length,checks,authentication:'UI login response simulated; native API, history and logout real. OS password verification is covered separately in Debian.'};
  console.log('BROWSER_LOGIN_RESULT '+JSON.stringify(result));
  return result;
}
