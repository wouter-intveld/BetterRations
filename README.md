# BetterRations

Self-updating macros for your best food, drink and bandage, for the World of
Warcraft Forever beta, which runs the Retail addon API.

## Install

Put this folder in `_classic_beta_/Interface/AddOns/BetterRations` and restart
the game. A `/reload` does not pick up changes to the `.toc` file.

## What it does

The addon creates three account-wide macros and keeps them up to date. Drag
them from the macro window (`/macro`) to your action bars.

| Macro        | Uses                                          |
| ------------ | --------------------------------------------- |
| `BR Eat`     | The food that restores the most health        |
| `BR Drink`   | The drink that restores the most mana         |
| `BR Bandage` | The strongest bandage your First Aid allows   |

- Only items you can use count: food and drink above your level and bandages
  above your First Aid skill are skipped.
- Conjured food and water win over anything that restores the same or less.
  Food that restores mana as well counts for both macros. Remaining ties go
  to the smallest stack, so your bags clear out.
- In combat, `BR Eat` uses your best healthstone instead of food. With
  potions turned on, `BR Drink` uses your best mana potion, and `BR Eat`
  steps through healthstone and healing potion: the first press in a fight
  uses the stone, the second the potion, and the order starts over when the
  fight ends. Without a healthstone it uses the potion straight away.
- Buff food (Well Fed) is left out of `BR Eat`. Use `/br buff` to include it.
- Macros cannot change in combat, so they update when combat ends.
- With nothing to use, the macro stays on your bar and says so when clicked.

## Commands

- `/br` - show the chosen items
- `/br options` - open the settings (also under Options > AddOns)
- `/br buff` - toggle buff food in `BR Eat`
- `/br potions` - toggle potions in combat
- `/br perf` - scan count, timing and memory

The settings turn buff food, the in-combat healthstone and potions on or off.
Potions are off by default.

## Limits

Items are recognised from their English tooltip text, so the addon only works
on English clients for now.
