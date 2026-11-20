# Vendor Printer

WoW Forever addon: finds recipes that make money when you buy the reagents (AH or vendor, whichever is cheaper) and sell the crafted item to a vendor. No AH reselling.

## Views (tabs in `/vp`)

| Tab | What | Revenue used |
| --- | --- | --- |
| Vendor (default) | Craft, sell to a vendor | Vendor sell price x avg output qty |
| AH sale (module `ah`) | Craft, sell on the AH | Cheapest AH listing x 0.95 (5% AH cut) x avg output qty; shows units listed as competition |
| Flips (module `flips`) | Buy from a vendor, sell on the AH | Cheapest AH listing x 0.95 minus vendor price; only vendors you've visited (`vendorSource` remembers who and where) |

Every tab has a **Profit %** column: profit as a share of the cost, `(what one sells for - cost) / cost`. On the AH sale tab "what one sells for" is the cheapest listing after the 5% cut; on Flips the cost is the vendor price.

Modules toggle with `/vp module ah|flips [on|off]`; off removes the tab, the extra items from the quick pass and the tooltip lines. Sell-side prices use `ahMin` (cheapest listing, what you'd match), buy-side uses `ah` (depth average). AH deposit is ignored (refunded on sale). Sell-through rate isn't available from the API: the listed count is the only competition signal.

## Install

`./install.sh` symlinks this folder into `_forever_/Interface/AddOns/`. Edit here, `/reload` in game.

## Use

1. Open each profession window once (records learned and unlearned recipes).
2. Visit merchants: their prices are recorded automatically.
3. Open the Auction House: prices update automatically (see "AH scanning" below).
4. `/vp` opens the list, sorted by profit per craft. Hover for reagent breakdown and how to learn. Click a recipe row to open its profession window on that recipe (`C_TradeSkillUI.OpenRecipe`, which needs the click as a hardware event; not in combat) and get a shopping list in chat.
5. At a vendor, **Alt+click** an item to buy any amount: type e.g. 193 and the addon makes the purchases (one purchase is capped at a stack, usually 20, so 193 = 9 x 20 + 1 x 13). A progress bar shows how far it got; it stops by itself when the vendor sells out, money runs out, or items stop arriving (bags full), and prints what it bought.

Commands: `/vp`, `/vp scan`, `/vp reagents`, `/vp depth <n>`, `/vp progress <milestones|all|off>`, `/vp tooltip`, `/vp module ah|flips [on|off]`, `/vp merchant [on|off]`, `/vp sound`, `/vp flipmin <silver> [percent]`, `/vp ahpanel`, `/vp log ...`, `/vp debug`, `/vp reset`, `/vp forget`, `/vp help`.

## AH scanning

| Mode | How | Speed | Limit |
| --- | --- | --- | --- |
| Full scan | One `ReplicateItems` request, whole AH | Usually seconds | Once per 15 min (server) |
| Reagent scan | Two passes over reagents of recorded recipes (all professions), see below | Quick pass: a few requests; detail: ~3 s per item (measured: 113 items took 367 s one by one) | None |

Reagent scan passes:
1. **Quick**: `SearchForItemKeys` in batches of 50 → cheapest price + total quantity per item. Covers reagents, plus crafted outputs (ah module) and recorded vendor items (flips module). Prices marked `ahQuick` ("cheapest listing only").
2. **Detail**: per-item `SendSearchQuery` for the depth price, only for AH-bought reagents of recipes still profitable (vendor or AH sale) or of unknown value at quick prices. Depth price >= cheapest price, so recipes losing money at cheapest prices are safely skipped.
Without `SearchForItemKeys` the scan falls back to detail-checking every reagent.

Auto-scan on AH open: full scan if off cooldown, else a reagent scan if the newest prices are older than 10 minutes. A reagent scan stops when the AH closes or a full scan starts; clicking its button again stops it. A reagent with zero listings has its old AH price removed; unanswered items keep their old price and a warning is printed. Note: reagent searches can show up in Blizzard's AH browse pane while running.

## Vendor flip alerts (`Merchant.lua`)

On every merchant visit, after the merchant is scanned, each gold-priced item is checked against AH prices (`ahMin` x 0.95 minus this vendor's price). Flips with at least `flipMinProfit` (default 1s) and `flipMinROI` (default 10%) get: a green glow + "+profit" on the merchant item button (follows page changes via `MerchantFrame_UpdateMerchantInfo`, hidden on buyback), a side panel docked to the merchant window (top 8, hover = item tooltip, click = details in chat, warns if AH prices are over a day old), one chat line and a coin sound per visit. No AH data yet → one tip per session to do a full scan. Overlays are kept in the addon's own table, never as fields on Blizzard frames (taint). `/vp merchant [on|off]`, `/vp sound`, `/vp flipmin <silver> [percent]`.

## Bulk buy (`BulkBuy.lua`)

Alt+left-click on a merchant item button (merchant tab only; this replaces the game's own Alt+click there) opens the "Buy in bulk" box with the price, the purchase count and the vendor's stock. Purchases go out one at a time (every 0.3 s, each waits for the items to arrive, 3 s timeout), each capped at `GetMerchantItemMaxStack` and the vendor's stock, and reduced to what you can afford. Items sold in lots (e.g. 5 per purchase) are rounded up to whole lots. Closing the merchant or the box stops it.

## AH panel (`AHPanel.lua`)

A small panel docked to the right of `AuctionHouseFrame` with Full scan (shows cooldown), Scan items (shows progress, click to stop) and Open list, plus price age. Button states come from `ns.FullScanButtonState` / `ns.ItemScanButtonState`, shared with the main window. `/vp ahpanel` toggles it; `/vp scan` and `/vp reagents` still work.

## Item tooltips

Any item tooltip (bags, merchant window, profession reagent/output icons, links) gets a "Vendor Printer" section when the item has a known price, is a reagent in recorded recipes, or is something you craft: AH flip profit + vendor name/zone (flips module), AH net for items you craft (ah module), AH price (depth avg, or "cheapest listing" after a quick pass, with thin-supply warning), vendor buy price (limited stock flagged), which is cheaper, how many of your recipes use it, and AH price age. Hooked via `TooltipDataProcessor.AddTooltipPostCall` (fallback `OnTooltipSetItem`). Skipped in combat and on comparison tooltips. `/vp tooltip` toggles it.

## Progress reporting

Long actions (both scans) show a movable on-screen bar (`Progress.lua`) with phase, done/total, % and ETA, plus chat lines: every 10% by default, `/vp progress all` for every item, `/vp progress off` for none. The window's reagent button shows `Stop Q 50/113` (quick) / `Stop D 3/8` (detail).

## How prices work

- Vendor price: lowest seen per unit. Items with limited stock are flagged.
- AH price: average unit price of the cheapest `depth` units (default 20), so one cheap listing doesn't fake a margin. Fewer units listed than `depth` is flagged ("only N on AH").
- Revenue: vendor sell price x average output quantity.
- Recipes with any unpriced reagent show "missing prices" (hide with the checkbox).

## Logging

Every meaningful action is logged (events, scan decisions and their reasons, per-item scan results and timings, recipe changes, skips, settings, slash commands, chat messages, errors with stacks). `Log.lua` holds the logger; each module uses `local log = ns.Logger("<Module>")`.

- Stored in SavedVariable `VendorPrinterLog` (ring buffer, last 5000 lines), written to disk on `/reload` or logout: `_forever_/WTF/Account/<ACCOUNT>/SavedVariables/VendorPrinter.lua`. Claude can read it there directly.
- Default level DEBUG. `/vp log [n]` shows the last n lines; `/vp log level <debug|info|warn|error>`; `/vp log echo [on|off]` mirrors new lines to chat live; `/vp log clear`.
- Errors inside event handlers, timers and debounced calls are caught with `xpcall`, logged with `debugstack`, then passed to WoW's normal error handler.
- High-frequency paths log only on change (recipe rescans on every craft, list rebuilds), and noisy events (`GET_ITEM_INFO_RECEIVED`, search result events) aren't logged per event.

## Files

| File | Role |
| --- | --- |
| `Log.lua` | Leveled, timestamped logger persisted to `VendorPrinterLog`; `SafeCall` error capture; `/vp log` commands |
| `Core.lua` | Namespace, SavedVariables defaults, event dispatch (errors logged), helpers, slash commands, `/vp debug` |
| `Progress.lua` | On-screen progress bar, chat milestones, ETA for long actions |
| `Prices.lua` | Merchant price recording, full AH scan (chunked, depth price, timeout), reagent scan (throttle-aware queue), auto-scan choice |
| `Recipes.lua` | Reads the open profession window, merges into per-character data; opens a recipe from a row click |
| `Calc.lua` | Cheapest source per reagent, profit/ROI, filters + sort, shopping lists |
| `Tooltip.lua` | Prices + recipe usage on item tooltips (reagent usage index rebuilt when recipes change) |
| `Merchant.lua` | Vendor flip alerts: item button glow, side panel, chat line + sound |
| `BulkBuy.lua` | Alt+click amount box at vendors; splits big purchases into stack-sized ones |
| `AHPanel.lua` | Scan buttons docked to the AH window |
| `UI.lua` | Window, rows, tooltips, search, crafts box, status bar |

SavedVariables: `VendorPrinterDB` (account: prices, settings), `VendorPrinterCharDB` (character: recipes).

## Status

- 2026-11-11: v0.1 written and tested outside the game with a mocked API (prices, scan, recipes, calc, shopping list, slash commands). Not yet run in game.
- Unverified on Forever: interface `16001`, exact API names. First thing in game: `/vp debug`.
- 2026-11-20: Profit % column, row click opens the recipe, Alt+click bulk buy. Tested in the addon sandbox (use cases `VendorPrinter/vendor-flips`, `ah-sale`, `bulk-buy`, and the sandbox's bulk-buy test); not yet in game. To check in game: the profession window opens on the right recipe (if `OpenRecipe` is blocked, the fallback opens the profession via its skill line), and the game's own Alt+click on merchant items doesn't also fire.

## Ideas (not built)

- Tooltip line on items showing their cheapest source
- Account-wide view across alts' professions
- Profit per hour / batch planning with your gold budget
