import { describe, expect, it } from "vitest";
import { browserURL, browserViewport, fitScale } from "./browser";

describe("browser addresses", () => {
  it("keeps full URLs, completes hosts and dev servers, and searches otherwise", () => {
    expect(browserURL("https://example.com/a")).toBe("https://example.com/a");
    expect(browserURL("localhost:3000")).toBe("http://localhost:3000/");
    expect(browserURL("192.168.1.4:8080/x")).toBe("http://192.168.1.4:8080/x");
    expect(browserURL("example.com")).toBe("https://example.com/");
    expect(browserURL("how to swift")).toBe("https://www.google.com/search?q=how+to+swift");
    expect(browserURL("file:///etc/passwd")).toBe("https://www.google.com/search?q=file%3A%2F%2F%2Fetc%2Fpasswd");
    expect(browserURL("  ")).toBeUndefined();
  });

  it("fits a device viewport inside the panel without enlarging it", () => {
    expect(browserViewport("phone", true)).toEqual({ width: 844, height: 390 });
    expect(fitScale({ width: 390, height: 844 }, { width: 1000, height: 1000 })).toBe(1);
    expect(fitScale({ width: 390, height: 844 }, { width: 390, height: 422 })).toBe(0.5);
  });
});
