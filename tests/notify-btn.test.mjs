import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const HTML = readFileSync(join(ROOT, "public/index.html"), "utf8");
const JS = readFileSync(join(ROOT, "public/js/app.js"), "utf8");

function functionSource(name) {
  const start = JS.indexOf("function " + name + "(");
  assert.notEqual(start, -1, "missing function " + name);
  const sigEnd = JS.indexOf(") {", start);
  const brace = JS.indexOf("{", sigEnd);
  let depth = 0;
  for (let i = brace; i < JS.length; i += 1) {
    if (JS[i] === "{") depth += 1;
    else if (JS[i] === "}") {
      depth -= 1;
      if (depth === 0) return JS.slice(start, i + 1);
    }
  }
  assert.fail("unclosed function " + name);
}

function storage(initial) {
  const store = Object.assign({}, initial);
  return {
    getItem: (key) => (Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null),
    setItem: (key, value) => {
      store[key] = String(value);
    },
  };
}

function loadNotifyHelpers(env) {
  const start = JS.indexOf('const NOTIFY_KEY = "piwebui.notify"');
  assert.notEqual(start, -1);
  const end = JS.indexOf("function writeNotifyPref", start);
  assert.notEqual(end, -1);
  const helpers = JS.slice(start, end);
  const context = vm.createContext({
    window: env.window || {},
    Notification: env.window && env.window.Notification,
    localStorage: env.localStorage,
  });
  vm.runInContext(helpers, context);
  return context;
}

describe("completion notification settings", () => {
  it("keeps the piwebui.notify key and only enables it with granted permission", () => {
    assert.match(JS, /const NOTIFY_KEY = "piwebui\.notify"/);
    const enabled = functionSource("notifyEnabled");
    assert.match(enabled, /readNotifyPref\(\)/);
    assert.match(enabled, /notificationPermissionState\(\)\s*===\s*"granted"/);

    const onPref = storage({ "piwebui.notify": "1" });
    const cases = [
      ["unsupported", {}, "unsupported", false],
      ["denied", { Notification: { permission: "denied" } }, "denied", false],
      ["default", { Notification: { permission: "default" } }, "default", false],
      ["granted", { Notification: { permission: "granted" } }, "granted", true],
    ];
    for (const [name, win, permission, expected] of cases) {
      const ctx = loadNotifyHelpers({ window: win, localStorage: onPref });
      assert.equal(ctx.notificationPermissionState(), permission, name);
      assert.equal(ctx.notifyEnabled(), expected, name);
    }

    const granted = { Notification: { permission: "granted" } };
    assert.equal(loadNotifyHelpers({ window: granted, localStorage: storage({ "piwebui.notify": "0" }) }).notifyEnabled(), false);
    assert.equal(loadNotifyHelpers({ window: granted, localStorage: storage() }).notifyEnabled(), false);
  });

  it("requests permission only when it is still default, and never from the render path", () => {
    const set = functionSource("setNotifyPref");
    assert.match(set, /Notification\.requestPermission/);
    assert.match(set, /permission === "default"/);
    assert.match(set, /writeNotifyPref\(false\)/);
    assert.match(set, /writeNotifyPref\(true\)/);
    assert.equal((JS.match(/Notification\.requestPermission/g) || []).length, 1);

    assert.doesNotMatch(functionSource("notificationPermissionState"), /requestPermission/);
    assert.doesNotMatch(functionSource("notifyEnabled"), /requestPermission/);
    assert.doesNotMatch(functionSource("openSettingsMenu"), /requestPermission/);
  });

  it("shows two explicit on / off rows under the notify group, with the current state checked", () => {
    const menu = functionSource("openSettingsMenu");
    assert.match(menu, /labelOnly: true, label: "通知"/);
    assert.match(menu, /label: "开", active: notifyOn/);
    assert.match(menu, /label: "关", active: !notifyOn/);
    assert.match(menu, /setNotifyPref\(true\)/);
    assert.match(menu, /setNotifyPref\(false\)/);
    assert.match(menu, /const notifyOn = notifyEnabled\(\)/);
    assert.doesNotMatch(menu, /完成时通知/);
    assert.doesNotMatch(menu, /toggleNotify/);
  });

  it("ships hollow bell and shirt symbols", () => {
    const bell = HTML.match(/<symbol id="i-bell"[\s\S]*?<\/symbol>/);
    const bellOff = HTML.match(/<symbol id="i-bell-off"[\s\S]*?<\/symbol>/);
    assert.ok(bell, "missing i-bell symbol");
    assert.ok(bellOff, "missing i-bell-off symbol");
    assert.match(bellOff[0], /M4 20L20 4/);

    for (const symbol of [bell[0], bellOff[0]]) {
      assert.doesNotMatch(symbol, /fill\s*:\s*currentColor/i);
      assert.doesNotMatch(symbol, /fill\s*=\s*["']?(?:currentColor|#[0-9a-f]{3,8})/i);
    }

    assert.ok(HTML.match(/<symbol id="i-shirt"[\s\S]*?<\/symbol>/), "missing i-shirt symbol");
  });
});
