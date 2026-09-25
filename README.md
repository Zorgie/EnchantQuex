# EnchantQuex

A World of Warcraft: Forever (1.60.x, interface 16001) addon that shows the expected disenchant value of
armor and weapons in their tooltips. It adds up the expected enchanting materials the item gives and prices
each one with Auctionator's Auction House scan data.

```
Disenchant                            1g 23s 45c
   1.16x Soul Dust (76%)                 92s 20c      <- hold Shift for the breakdown
   0.30x Greater Astral Essence (19%)    31s 25c
   0.05x Large Glimmering Shard (5%)        10s
   Uncommon armor ilvl 26 (14 items, 5210 disenchants)
```

## Install

Copy (or symlink) the `EnchantQuex` folder into `World of Warcraft/_classic_beta_/Interface/AddOns/`
(this becomes `_forever_` or similar at launch). Install **Auctionator** and do a full AH scan so material prices
exist.

## Where the numbers come from

Disenchant results depend on an item's **rarity**, **class** (all armor is one class, all weapons another) and
**item level**. The addon keeps one material table per combination and looks it up with the item's in-game
(Forever) rarity and item level. Per-item data is never used.

The tables are built from [Wowhead Classic](https://www.wowhead.com/classic) observations. Wowhead's Forever
database shows the same Classic observations but with Forever item levels and rarities, which is wrong for items
that changed. Classic's data is self-consistent.

For each material the table stores the drop chance and the average quantity when it drops, averaged over all
observed items in the group and weighted by how often each was disenchanted. Expected quantity = chance × average
quantity.

If a combination has no table, the nearest item level within 5 (configurable) is used and the tooltip shows the
ⓘ **est.** marker.

Price per material = Auctionator's latest scanned price (`Auctionator.API.v1.GetAuctionPriceByItemID`).
Materials without AH data are skipped and the total shows `+?`.

## Overrides

Click the minimap button (or `/eqx`) to open the options panel. Under **Material table overrides**, pick a rarity,
class and item level, edit the chance (%) and average quantity for each material, and click **Save override**.
An override always replaces the Wowhead table for that combination, including when it's picked up as the nearest
item level. **Remove override** goes back to the Wowhead data. Overrides are saved per account in
`EnchantQuexDB`.

## Commands

| Command | Effect |
|---|---|
| `/eqx` | open the options panel |
| `/eqx status` | print current settings |
| `/eqx toggle` | enable/disable the tooltip line |
| `/eqx distance <n>` | how far to search neighbouring item levels (default 5) |
| `/eqx breakdown` | always show the material breakdown instead of on Shift |
| `/eqx minimap` | show/hide the minimap button |
| `/eqx prices` | print every material's Auctionator price and how old it is |

## Updating the data

The tables are generated into `EnchantQuex/Data.lua`:

```
py tools/scrape_wowhead.py            # reuses pages cached in tools/cache/classic/
py tools/scrape_wowhead.py --refresh  # re-download everything
```

The scraper reads each material's "disenchanted-from" list and the "Disenchants into" item filters. It then
fetches individual item pages for groups up to item level 40 until each has 1000 observed disenchants,
rewriting Data.lua after every round. It waits 5 seconds between requests. If Wowhead rate-limits it, it saves what
it has, and the next run resumes from the cache.
