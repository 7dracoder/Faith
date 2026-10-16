import { test, expect } from "playwright/test";
import AxeBuilder from "@axe-core/playwright";

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".option-card")).toHaveCount(8);
});

test("all categories can be searched and review requires an explicit acknowledgement", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  for (const [category, count] of [["flight", 1], ["train", 2], ["bus", 1], ["cinema", 2], ["event", 2]]) {
    await page.locator(`[data-category="${category}"]`).click();
    await page.getByRole("button", { name: "Find tickets", exact: true }).click();
    await expect(page.locator(".option-card")).toHaveCount(count);
    await expect(page.locator("#results")).toHaveAttribute("aria-busy", "false");
  }
  await page.locator("[data-review]").first().click();
  await expect(page.getByRole("dialog", { name: "Let’s check the details." })).toBeVisible();
  await expect(page.locator("#confirm-booking")).toBeDisabled();
  await page.locator("#accept-demo").check();
  await page.locator("#confirm-booking").click();
  await expect(page.locator(".wallet-card")).toHaveCount(1);
  await expect(page.locator(".wallet-card")).toContainText("NOT VALID FOR ENTRY");
  await expect(page.locator(".wallet-card")).toContainText("No payment made");
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: /Download demo ticket/ }).click();
  expect((await download).suggestedFilename()).toMatch(/^Faith-FTH-.+\.txt$/);
  await page.reload();
  await page.locator("#nav-tickets").click();
  await expect(page.locator(".wallet-card")).toHaveCount(1);
  await page.getByRole("button", { name: /Cancel demo ticket for/ }).click();
  await expect(page.locator("#cancel-dialog")).toBeVisible();
  await page.locator("#confirm-cancel").click();
  await expect(page.locator(".ticket-status")).toHaveText("DEMO CANCELLED");
  expect(errors).toEqual([]);
});

test("natural-language search prepares editable fields and group prices include fees", async ({ page }) => {
  await page.locator("#request").fill("Two train tickets to Boston tomorrow under $150");
  await page.locator("#interpret").click();
  await expect(page.locator("#passengers")).toHaveValue("2");
  await expect(page.locator("#budget")).toHaveValue("150");
  await expect(page.locator('[data-category="train"]')).toHaveAttribute("aria-pressed", "true");
  await page.getByRole("button", { name: "Find tickets", exact: true }).click();
  await expect(page.locator(".option-card")).toHaveCount(2);
  await expect(page.locator(".price").first()).toContainText("$103");
  await page.locator("[data-review]").first().click();
  await expect(page.locator(".line-item.total")).toContainText("$103");
});

test("empty results offer recovery and access preferences persist", async ({ page }) => {
  await page.locator('[data-category="flight"]').click();
  await page.locator('input[name="captions"]').check();
  await page.getByRole("button", { name: "Find tickets", exact: true }).click();
  await expect(page.locator("#empty-state")).toBeVisible();
  await page.locator("#clear-filters").click();
  await expect(page.locator(".option-card")).toHaveCount(1);
  await page.locator("#open-access").click();
  await page.locator("#setting-large").check();
  await page.locator("#setting-contrast").check();
  await page.locator("#setting-reduced").check();
  await page.keyboard.press("Escape");
  await expect(page.locator("#open-access")).toBeFocused();
  await page.reload();
  await expect(page.locator("body")).toHaveClass(/large-text/);
  await expect(page.locator("body")).toHaveClass(/high-contrast/);
  await expect(page.locator("body")).toHaveClass(/reduced-motion/);
});

test("keyboard entry, responsive layout, and automated accessibility checks", async ({ page }) => {
  await page.keyboard.press("Tab");
  await expect(page.locator(".skip-link")).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page.locator("#main")).toBeFocused();
  const home = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa"]).analyze();
  expect(home.violations).toEqual([]);
  await page.locator("[data-review]").first().click();
  const review = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa"]).analyze();
  expect(review.violations).toEqual([]);
  await page.keyboard.press("Escape");
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator("#open-access")).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.locator("#open-access").click();
  await page.locator("#setting-large").check();
  await page.keyboard.press("Escape");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("network failure does not create a ticket and can be retried", async ({ page }) => {
  await page.locator("[data-review]").first().click();
  await page.locator("#accept-demo").check();
  await page.route("**/api/bookings", (route) => route.request().method() === "POST" ? route.abort() : route.continue());
  await page.locator("#confirm-booking").click();
  await expect(page.locator("#review-error")).not.toHaveText("");
  await expect(page.locator("#confirm-booking")).toBeEnabled();
  await page.unroute("**/api/bookings");
  await page.locator("#confirm-booking").click();
  await expect(page.locator(".wallet-card")).toHaveCount(1);
});

test("optional motion changes focus without activating or confirming a ticket", async ({ page }) => {
  // Supply a synthetic sensor even on headless hosts without the platform API.
  await page.evaluate(() => {
    window.DeviceOrientationEvent = class extends Event {
      constructor(type, { gamma }) { super(type); this.gamma = gamma; }
    };
  });
  await page.locator("#open-access").click();
  await page.locator("#toggle-motion").click();
  await expect(page.locator("#sensor-status")).toHaveText("Motion: calibrating…");
  await page.evaluate(() => window.dispatchEvent(new DeviceOrientationEvent("deviceorientation", { gamma: 0 })));
  await expect(page.locator("#sensor-status")).toHaveText("Tilt controls ready");
  await page.getByRole("button", { name: "Done, make it mine" }).click();
  await page.evaluate(() => window.dispatchEvent(new DeviceOrientationEvent("deviceorientation", { gamma: 22 })));
  await expect(page.locator("[data-review]").first()).toBeFocused();
  await expect(page.locator("#review-dialog")).not.toBeVisible();
  await expect(page.locator("#ticket-count")).toBeHidden();
  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { value: true, configurable: true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await expect(page.locator("#sensor-status")).toHaveText("Text & touch ready");
});

test("browsers without a motion API retain text and touch booking", async ({ page }) => {
  await page.evaluate(() => { window.DeviceOrientationEvent = undefined; });
  await page.locator("#open-access").click();
  await page.locator("#toggle-motion").click();
  await expect(page.locator("#motion-note")).toContainText("Motion isn’t available");
  await expect(page.locator("#sensor-status")).toHaveText("Text & touch ready");
  await page.getByRole("button", { name: "Done, make it mine" }).click();
  await page.locator("[data-review]").first().click();
  await expect(page.locator("#review-dialog")).toBeVisible();
  await expect(page.locator("#confirm-booking")).toBeDisabled();
});
