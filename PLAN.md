# Do I Need This? — Plan

## Decisions
- Client: Interface 16001 (build 1.60.1). Modern client, Lua 5.1, `C_*` APIs.
- Data stored as realm → faction → character, in one shared `DoINeedThisDB` for the account.
- Single WoW account only (no cross-account sync for now).
- Mail between alts arrives instantly, so there's no delivery timer. Sent items count as "in mailbox" until the recipient picks them up.
- Allocation: for each item, fill the highest-priority character first. The sender has no special rules and just takes its place in the priority list.
- A fallback character per realm/faction gets the excess (for storing or selling).
- Low-level characters still receive items.
- One click on the mail window sends every mail needed.
- Tooltip shows who needs the item and who already has it in their own bank.
- Folder/addon name `DoINeedThis` (`?` isn't allowed in Windows file names). Display title "Do I Need This?".

## Phases
1. Skeleton: toc, events, saved data, `/dint` dump. **(done)**
2. Recording: quests, bags, bank. **(done; mailbox still to do)**
3. Need calculation and overview window.
4. Mail-window button and send queue (preview → send, record what was sent).
5. Mailbox scan: check off sent mail once it's collected.
6. Settings: priority order, fallback character, excluded characters.
7. Tooltip, minimap button, fill out quest data.
