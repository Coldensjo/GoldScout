# Gold Scout

A World of Warcraft addon that records what each of your characters has and can do, so you can plan gold making offline and across characters.

It keeps track of:

- **Characters:** professions, recipes, bags, bank and mail
- **Vendors:** what vendors stock, so you can find items to buy and resell
- **Auctions:** what you post, sell, buy, and what expires or is cancelled, plus copies of Auctionator full scans
- **Gathering and loot:** every node you gather and everything you loot, grouped into play sessions
- **Spending:** where your money comes from and where it goes
- **Progress:** levels, experience, kills, quests, skills, reputation, dungeons, PvP and time played
- **Raids:** who you grouped with, boss kills and wipes, loot rolls, who received what, and your guild roster
- **Journal:** a log of nearly everything that touches gold or items

Everything is stored in the `GoldScoutDB` saved variable. The game writes it to disk when you `/reload`, log out or exit.

## Requirements

- WoW client with interface version 16001 (the Classic "Forever" beta)
- Optional: [Auctionator](https://www.curseforge.com/wow/addons/auctionator), for auction prices and scans

## Installation

Copy the `GoldScout` folder into `World of Warcraft\_classic_beta_\Interface\AddOns\`, then restart the game or `/reload`.

## Usage

| Command | What it does |
| --- | --- |
| `/gs` or `/goldscout` | Open or close the overview window |
| `/gs <tab>` | Open the overview on a tab, such as `chars`, `items`, `craft`, `vendors`, `stats`, `progress`, `raid` or `journal` |
| `/gs minimap` | Show or hide the minimap button |
| `/gs debug` | Turn debug messages on or off |

Left-click the minimap button to open the overview, right-click it to toggle debug messages, and drag it to move it around the minimap.

## Market data

`MarketData.lua` is a placeholder. An external auction house sync tool overwrites the installed copy with estimated sales and sellers after every sync. Don't copy the placeholder over an installed copy, or you'll lose that data until the next sync.

## License

[MIT](LICENSE)
