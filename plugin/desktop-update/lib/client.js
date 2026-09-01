window.__ModuleLoader__.load({
	id: "@cedardsh/desktop-update",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		const React = require("react");
		const { IconRefreshOutline16 } = require("@deepseek-ai/dsh-client-ui-primitives");

		const STYLE_ID = "cedardsh-desktop-update-style";
		const STYLE = `
.cedardshUpdateAnchor {
  display: contents;
}

*:has(> div > .cedardshUpdateAnchor:not(.cedardshUpdateRail)) {
  position: relative;
  z-index: 4;
  overflow: visible;
}

.cedardshUpdateButton {
  position: absolute;
  top: calc(100% + 11px);
  right: 6px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  height: 28px;
  padding: 0 9px;
  border: 1px solid var(--dsw-alias-border-l2);
  border-radius: 9px;
  background: var(--dsw-alias-button-elevated-fill);
  color: var(--dsw-alias-label-primary);
  font: inherit;
  font-size: 13px;
  line-height: 20px;
  cursor: pointer;
  white-space: nowrap;
}

.cedardshUpdateButton:hover {
  background: var(--dsw-alias-button-floating-hover);
}

.cedardshUpdateAnchor.cedardshUpdateRail {
  display: flex;
  width: 36px;
  height: 36px;
}

.cedardshUpdateRail .cedardshUpdateButton {
  position: static;
  width: 36px;
  height: 36px;
  padding: 0;
  border-color: transparent;
  border-radius: 50%;
  background: transparent;
}

.cedardshUpdateRail .cedardshUpdateButton:hover {
  background: var(--dsw-alias-interactive-bg-hover);
}

.cedardshAboutSection {
  max-width: 620px;
  padding: 8px 0 24px;
  color: var(--dsw-alias-label-primary);
}

.cedardshAboutSection h2 {
  margin: 0;
  font-size: 24px;
  line-height: 34px;
  font-weight: 600;
}

.cedardshAboutIntro,
.cedardshAboutNote {
  margin: 8px 0 0;
  color: var(--dsw-alias-label-secondary);
  font-size: 13px;
  line-height: 20px;
}

.cedardshAboutCard {
  margin-top: 22px;
  padding: 6px 18px;
  border: 1px solid var(--dsw-alias-border-l2);
  border-radius: 14px;
  background: var(--dsw-alias-bg-layer-1);
}

.cedardshAboutCard dl {
  margin: 0;
}

.cedardshAboutRow {
  display: grid;
  grid-template-columns: minmax(150px, 1fr) minmax(220px, 1.4fr);
  gap: 20px;
  padding: 13px 0;
  border-bottom: 1px solid var(--dsw-alias-border-l2);
  font-size: 14px;
  line-height: 22px;
}

.cedardshAboutRow:last-child {
  border-bottom: 0;
}

.cedardshAboutRow dt {
  color: var(--dsw-alias-label-secondary);
}

.cedardshAboutRow dd {
  margin: 0;
  text-align: right;
  overflow-wrap: anywhere;
}

.cedardshAboutActions {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-top: 20px;
}

.cedardshAboutActions button {
  height: 36px;
  padding: 0 14px;
  border: 1px solid var(--dsw-alias-border-l2);
  border-radius: 10px;
  background: var(--dsw-alias-button-elevated-fill);
  color: var(--dsw-alias-label-primary);
  font: inherit;
  font-size: 14px;
  cursor: pointer;
}

.cedardshAboutActions button:hover {
  background: var(--dsw-alias-button-floating-hover);
}
`;

		const NS = "cedardsh-update";
		const dictionaries = {
			zh: {
				action: "更新",
				aboutNav: "关于",
				aboutTitle: "CedarDSH Desktop",
				aboutIntro: "面向 Windows 的 DeepSeek Harness 桌面便携版。",
				desktopVersion: "桌面版本",
				dshVersion: "官方 DSH 版本",
				builtAt: "构建时间",
				lastUpdateCheck: "上次检查更新",
				never: "尚未检查",
				releases: "查看更新内容",
				diagnostics: "复制诊断信息",
				diagnosticNote: "诊断信息不包含日志正文、API 密钥或访问令牌。",
			},
			en: {
				action: "Update",
				aboutNav: "About",
				aboutTitle: "CedarDSH Desktop",
				aboutIntro: "A portable DeepSeek Harness desktop app for Windows.",
				desktopVersion: "Desktop version",
				dshVersion: "Official DSH version",
				builtAt: "Built",
				lastUpdateCheck: "Last update check",
				never: "Not checked yet",
				releases: "View release notes",
				diagnostics: "Copy diagnostics",
				diagnosticNote: "Diagnostics contain no log text, API keys, or access tokens.",
			},
		};

		function openDesktopAction(path, name) {
			window.open(new URL(path, window.location.href).href, name);
		}

		function UpdateButton({ wide, t }) {
			const label = t("action");
			const requestUpdate = () => {
				openDesktopAction("/__cedardsh/update", "cedardsh-update");
			};
			return React.createElement(
				"span",
				{
					className: wide
						? "cedardshUpdateAnchor"
						: "cedardshUpdateAnchor cedardshUpdateRail",
				},
				React.createElement(
					"button",
					{
						type: "button",
						className: "cedardshUpdateButton",
						"data-cedardsh-update": "",
						"aria-label": label,
						title: label,
						onClick: requestUpdate,
					},
					React.createElement(IconRefreshOutline16, { size: wide ? 14 : 18 }),
					wide ? React.createElement("span", null, label) : null,
				),
			);
		}

		function AboutRow({ label, value }) {
			return React.createElement(
				"div",
				{ className: "cedardshAboutRow" },
				React.createElement("dt", null, label),
				React.createElement("dd", null, value),
			);
		}

		function AboutSection({ t }) {
			const info = window.__CEDARDSH_DESKTOP_INFO__;
			const timestamp = (value) => value === null ? t("never") : new Date(value).toLocaleString();
			return React.createElement(
				"section",
				{ className: "cedardshAboutSection", "data-cedardsh-about": "" },
				React.createElement("h2", null, t("aboutTitle")),
				React.createElement("p", { className: "cedardshAboutIntro" }, t("aboutIntro")),
				React.createElement(
					"div",
					{ className: "cedardshAboutCard" },
					React.createElement(
						"dl",
						null,
						React.createElement(AboutRow, { label: t("desktopVersion"), value: info.portableVersion }),
						React.createElement(AboutRow, { label: t("dshVersion"), value: info.dshVersion }),
						React.createElement(AboutRow, { label: t("builtAt"), value: timestamp(info.builtAt) }),
						React.createElement(AboutRow, { label: t("lastUpdateCheck"), value: timestamp(info.lastCheckedAt) }),
					),
				),
				React.createElement(
					"div",
					{ className: "cedardshAboutActions" },
					React.createElement("button", {
						type: "button",
						"data-cedardsh-releases": "",
						onClick: () => { openDesktopAction("/__cedardsh/releases", "cedardsh-releases"); },
					}, t("releases")),
					React.createElement("button", {
						type: "button",
						"data-cedardsh-diagnostics": "",
						onClick: () => { openDesktopAction("/__cedardsh/diagnostics", "cedardsh-diagnostics"); },
					}, t("diagnostics")),
				),
				React.createElement("p", { className: "cedardshAboutNote" }, t("diagnosticNote")),
			);
		}

		const inject = ["slots", "locale"];

		function apply(ctx) {
			ctx.effect(() => ctx.locale.register(NS, dictionaries), "cedardsh-update: dictionaries");
			const t = ctx.locale.bind(NS);
			ctx.effect(() => {
				if (document.getElementById(STYLE_ID) !== null) return undefined;
				const style = document.createElement("style");
				style.id = STYLE_ID;
				style.textContent = STYLE;
				document.head.append(style);
				return () => { style.remove(); };
			}, "cedardsh-update: styles");
			ctx.slots.inject("sidebar.footer.action", () => ctx.slots.register({
				name: "sidebar.footer.action",
				id: "cedardsh-update",
				order: 1000,
				locale: NS,
			}, UpdateButton));
			ctx.slots.inject("settings.section", () => ctx.slots.register({
				name: "settings.section",
				id: "cedardsh-about",
				order: 100,
				label: () => t("aboutNav"),
				locale: NS,
			}, AboutSection));
		}

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
