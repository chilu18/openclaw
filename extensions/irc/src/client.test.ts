import { describe, expect, it } from "vitest";
import { buildFallbackNick, buildIrcNickServCommands } from "./client.js";

describe("irc client nickserv", () => {
  it("builds IDENTIFY command when password is set", () => {
    expect(
      buildIrcNickServCommands({
        password: "secret",
      }),
    ).toEqual(["PRIVMSG NickServ :IDENTIFY secret"]);
  });

  it("builds REGISTER command when enabled with email", () => {
    expect(
      buildIrcNickServCommands({
        password: "secret",
        register: true,
        registerEmail: "bot@example.com",
      }),
    ).toEqual([
      "PRIVMSG NickServ :IDENTIFY secret",
      "PRIVMSG NickServ :REGISTER secret bot@example.com",
    ]);
  });

  it("rejects register without registerEmail", () => {
    expect(() =>
      buildIrcNickServCommands({
        password: "secret",
        register: true,
      }),
    ).toThrow(/registerEmail/);
  });

  it("sanitizes outbound NickServ payloads", () => {
    expect(
      buildIrcNickServCommands({
        service: "NickServ\n",
        password: "secret\r\nJOIN #bad",
      }),
    ).toEqual(["PRIVMSG NickServ :IDENTIFY secret JOIN #bad"]);
  });
});

describe("irc fallback nick generation", () => {
  it("uses numbered fallbacks after the first collision", () => {
    expect(buildFallbackNick("openclaw-bot", 1)).toBe("openclaw-bot_");
    expect(buildFallbackNick("openclaw-bot", 2)).toBe("openclaw-bot_2");
    expect(buildFallbackNick("openclaw-bot", 3)).toBe("openclaw-bot_3");
  });

  it("sanitizes nicknames and preserves bounded max length", () => {
    expect(buildFallbackNick("open claw! bot", 2)).toBe("openclawbot_2");

    const longNick = "abcdefghijklmnopqrstuvwxyz1234567890";
    const firstFallback = buildFallbackNick(longNick, 1);
    const tenthFallback = buildFallbackNick(longNick, 10);

    expect(firstFallback.length).toBeLessThanOrEqual(30);
    expect(tenthFallback.length).toBeLessThanOrEqual(30);
    expect(firstFallback.endsWith("_")).toBe(true);
    expect(tenthFallback.endsWith("_10")).toBe(true);
  });
});
