import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const JS = readFileSync(join(ROOT, "public/js/app.js"), "utf8");
const HTML = readFileSync(join(ROOT, "public/index.html"), "utf8");
const CSS = readFileSync(join(ROOT, "public/styles.css"), "utf8");

function functionSource(name) {
  const start = JS.indexOf("function " + name + "(");
  assert.notEqual(start, -1, "missing function " + name);
  const brace = JS.indexOf("{", start);
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

// 明暗 / 皮肤这一段只依赖 window.matchMedia、document 和 localStorage，
// 放在 vm 里跑真函数，比逐个正则更贴近实际行为。
function loadAppearanceHelpers(options = {}) {
  const start = JS.indexOf("const systemTheme");
  const end = JS.indexOf("function openSettingsMenu", start);
  assert.notEqual(start, -1);
  assert.notEqual(end, -1);

  const store = Object.assign({}, options.store);
  const dataset = {};
  const meta = { attrs: {}, setAttribute(name, value) { this.attrs[name] = value; } };
  const context = vm.createContext({
    window: { matchMedia: () => ({ matches: Boolean(options.dark), addEventListener() {} }) },
    document: {
      documentElement: { dataset },
      querySelector: (selector) => (selector === 'meta[name="theme-color"]' ? meta : null),
    },
    localStorage: {
      getItem: (key) => (Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null),
      setItem: (key, value) => {
        store[key] = String(value);
      },
    },
  });
  vm.runInContext(
    JS.slice(start, end) +
      "\nglobalThis.applyTheme = applyTheme; globalThis.applySkin = applySkin; globalThis.currentSkin = currentSkin;" +
      " globalThis.themePreference = themePreference; globalThis.SKINS = SKINS;",
    context,
  );
  return { ctx: context, store, dataset, meta };
}

describe("settings menu appearance controls", () => {
  it("applyTheme persists the preference, sets mode/theme and updates the theme-color meta", () => {
    const apply = functionSource("applyTheme");
    assert.match(apply, /dataset\.mode = next/);
    assert.match(apply, /dataset\.theme = resolved/);
    assert.match(apply, /localStorage\.setItem\("piwebui\.theme", next\)/);
    assert.match(apply, /meta\.setAttribute\("content", resolved === "dark" \? "#000000" : "#ffffff"\)/);

    const light = loadAppearanceHelpers();
    light.ctx.applyTheme("light");
    assert.equal(light.store["piwebui.theme"], "light");
    assert.equal(light.dataset.mode, "light");
    assert.equal(light.dataset.theme, "light");
    assert.equal(light.meta.attrs.content, "#ffffff");

    const unknown = loadAppearanceHelpers();
    unknown.ctx.applyTheme("not-a-mode");
    assert.equal(unknown.store["piwebui.theme"], "dark");
    assert.equal(unknown.dataset.mode, "dark");
    assert.equal(unknown.dataset.theme, "dark");
    assert.equal(unknown.meta.attrs.content, "#000000");

    const systemLight = loadAppearanceHelpers({ dark: false });
    systemLight.ctx.applyTheme("system");
    assert.equal(systemLight.store["piwebui.theme"], "system");
    assert.equal(systemLight.dataset.mode, "system");
    assert.equal(systemLight.dataset.theme, "light");
    assert.equal(systemLight.meta.attrs.content, "#ffffff");

    const systemDark = loadAppearanceHelpers({ dark: true });
    systemDark.ctx.applyTheme("system");
    assert.equal(systemDark.dataset.theme, "dark");
    assert.equal(systemDark.meta.attrs.content, "#000000");
  });

  it("applySkin persists the choice and sets data-skin, currentSkin reads the key", () => {
    assert.match(JS, /const SKINS = \[/);
    const skinIds = loadAppearanceHelpers().ctx.SKINS.map((skin) => skin.id);
    assert.deepEqual(Array.from(skinIds), ["classic", "paper", "cyber", "sea-salt", "aurora", "mint"]);

    const apply = functionSource("applySkin");
    assert.match(apply, /dataset\.skin = skin/);
    assert.match(apply, /localStorage\.setItem\("piwebui\.skin", skin\)/);
    assert.match(functionSource("currentSkin"), /piwebui\.skin/);

    const picked = loadAppearanceHelpers({ store: { "piwebui.skin": "mint" } });
    assert.equal(picked.ctx.currentSkin(), "mint");
    picked.ctx.applySkin("aurora");
    assert.equal(picked.store["piwebui.skin"], "aurora");
    assert.equal(picked.dataset.skin, "aurora");

    const alias = loadAppearanceHelpers({ store: { "piwebui.skin": "mint-clay" } });
    assert.equal(alias.ctx.currentSkin(), "mint");

    const fallback = loadAppearanceHelpers({ store: { "piwebui.skin": "gone" } });
    assert.equal(fallback.ctx.currentSkin(), "classic");
    fallback.ctx.applySkin("gone");
    assert.equal(fallback.dataset.skin, "classic");
    assert.equal(fallback.store["piwebui.skin"], "classic");

    assert.equal(loadAppearanceHelpers().ctx.currentSkin(), "classic");
  });

  it("boot applies the saved theme and skin, and the inline boot script reads both keys", () => {
    assert.match(JS, /localStorage\.getItem\("piwebui\.theme"\) \|\| "system"/);
    const boot = functionSource("boot");
    assert.match(boot, /applyTheme\(theme === "light" \|\| theme === "system" \? theme : "dark"\)/);
    assert.match(boot, /applySkin\(localStorage\.getItem\("piwebui\.skin"\) \|\| SKINS\[0\]\.id\)/);
    assert.match(boot, /dataset\.mode === "system"\) applyTheme\("system"\)/);

    const htmlBoot = HTML.slice(HTML.indexOf("<script>"), HTML.indexOf("</script>"));
    assert.match(htmlBoot, /localStorage\.getItem\("piwebui\.theme"\) \|\| "system"/);
    assert.match(htmlBoot, /dataset\.mode = mode/);
    assert.match(htmlBoot, /dataset\.theme = resolved/);
    assert.match(htmlBoot, /dataset\.skin = localStorage\.getItem\("piwebui\.skin"\) \|\| "classic"/);
    assert.match(htmlBoot, /prefers-color-scheme: dark/);

    assert.doesNotMatch(CSS, /theme-mode-dark|theme-mode-light|theme-mode-system/);
  });

  it("groups notification, light/dark and skins in the settings menu", () => {
    const menu = functionSource("openSettingsMenu");
    assert.match(menu, /labelOnly: true, label: "通知"/);
    assert.match(menu, /labelOnly: true, label: "明暗"/);
    assert.match(menu, /labelOnly: true, label: "皮肤"/);
    assert.ok(menu.indexOf('label: "通知"') < menu.indexOf('label: "明暗"'), "通知 should come before 明暗");
    assert.ok(menu.indexOf('label: "明暗"') < menu.indexOf('label: "皮肤"'), "明暗 should come before 皮肤");
    assert.match(menu, /applyTheme\("light"\)/);
    assert.match(menu, /applyTheme\("dark"\)/);
    assert.match(menu, /applyTheme\("system"\)/);
    assert.match(menu, /SKINS\.map\(/);
    assert.match(menu, /applySkin\(skin\.id\)/);

    assert.match(JS, /el\.settingsBtn\.addEventListener\("click", \(\) => openSettingsMenu\(el\.settingsBtn\)\)/);
  });

  it("uses a #settingsBtn menu button and Cmd/Ctrl+, shortcut instead of the old appearance button", () => {
    const btn = HTML.match(/<button[^>]*id="settingsBtn"[^>]*>[\s\S]*?<\/button>/);
    assert.ok(btn, "missing #settingsBtn");
    assert.match(btn[0], /type="button"/);
    assert.match(btn[0], /aria-haspopup="menu"/);
    assert.match(btn[0], /aria-expanded="false"/);
    assert.match(btn[0], /#i-dots/);

    assert.match(
      JS,
      /if \(meta && event\.key === ","\) \{\s*event\.preventDefault\(\);\s*openSettingsMenu\(el\.settingsBtn\);/,
    );

    assert.doesNotMatch(JS, /themeBtn|openAppearanceMenu/);
    assert.doesNotMatch(HTML, /themeBtn|openAppearanceMenu/);
    assert.doesNotMatch(CSS, /#themeBtn|#notifyBtn/);
  });
});
