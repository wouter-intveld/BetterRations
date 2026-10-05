// Generates Data.lua: what each consumable restores, from the game's own
// data tables (wago.tools), so the addon needs no tooltip text and works in
// every client language.
//
//   bun tools/gen-data.js            (product defaults to wow_cn_beta, the 1.60.1 build)
//   bun tools/gen-data.js <product>

const PRODUCT = process.argv[2] ?? "wow_cn_beta";

function parseCSV(text) {
    const rows = [];
    let row = [], field = "", quoted = false;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (quoted) {
            if (c === '"') {
                if (text[i + 1] === '"') { field += '"'; i++; } else quoted = false;
            } else field += c;
        } else if (c === '"') quoted = true;
        else if (c === ",") { row.push(field); field = ""; }
        else if (c === "\n") { row.push(field); rows.push(row); row = []; field = ""; }
        else if (c !== "\r") field += c;
    }
    if (field || row.length) { row.push(field); rows.push(row); }
    const head = rows.shift();
    return rows.map(r => Object.fromEntries(head.map((k, i) => [k, r[i]])));
}

async function table(name) {
    const res = await fetch(`https://wago.tools/db2/${name}/csv?product=${PRODUCT}`);
    if (!res.ok) throw new Error(`${name}: HTTP ${res.status}`);
    return parseCSV(await res.text());
}

function group(rows, key) {
    const m = new Map();
    for (const r of rows) {
        if (!m.has(r[key])) m.set(r[key], []);
        m.get(r[key]).push(r);
    }
    return m;
}

const [items, sparse, itemEffects, links, effects, misc, durations] = await Promise.all(
    ["Item", "ItemSparse", "ItemEffect", "ItemXItemEffect", "SpellEffect", "SpellMisc", "SpellDuration"].map(table));

const CONSUMABLE = "0";
const SUB = { potion: "1", food: "5", bandage: "7" };
const EFFECT = { applyAura: "6", heal: "10", energize: "30", triggerSpell: "64" };
const AURA = { periodicHeal: "8", regen: "84", powerRegen: "85", wellFed: "227" };
const ITEM_FLAG_CONJURED = 0x2;

const sparseByID = new Map(sparse.map(r => [r.ID, r]));
const effectByID = new Map(itemEffects.map(r => [r.ID, r]));
const effectsBySpell = group(effects, "SpellID");
const miscBySpell = new Map(misc.map(r => [r.SpellID, r]));
const durationByID = new Map(durations.map(r => [r.ID, r]));
const spellsByItem = new Map();
for (const l of links) {
    const e = effectByID.get(l.ItemEffectID);
    if (!e || e.TriggerType !== "0") continue; // 0 = on use
    if (!spellsByItem.has(l.ItemID)) spellsByItem.set(l.ItemID, []);
    spellsByItem.get(l.ItemID).push(e.SpellID);
}

const duration = spellID => Number(durationByID.get(miscBySpell.get(spellID)?.DurationIndex)?.Duration ?? 0);

// Food and drink regen auras have no tick period in the data; the client's
// tooltip total ($o1) matches base * duration / 5200, rounded down.
const regenTotal = (base, ms) => Math.floor(base * ms / 5200);
// Instant heals roll base +- variance/2; rank by the low end, like the tooltip.
const lowEnd = (base, variance) => Math.floor(base * (1 - variance / 2));

function scan(spellID, info, depth = 0) {
    for (const e of effectsBySpell.get(spellID) ?? []) {
        const base = Number(e.EffectBasePointsF);
        if (e.Effect === EFFECT.triggerSpell && depth < 2) {
            // Buff food: the triggered spell is the plain food, the aura below is Well Fed.
            scan(e.EffectTriggerSpell, info, depth + 1);
        } else if (e.Effect === EFFECT.applyAura) {
            if (e.EffectAura === AURA.regen) info.health += regenTotal(base, duration(spellID));
            else if (e.EffectAura === AURA.powerRegen && e.EffectMiscValue_0 === "0") info.mana += regenTotal(base, duration(spellID));
            else if (e.EffectAura === AURA.periodicHeal && Number(e.EffectAuraPeriod) > 0) {
                info.periodic += base * Math.floor(duration(spellID) / Number(e.EffectAuraPeriod));
            } else if (e.EffectAura === AURA.wellFed) info.wellFed = true;
        } else if (e.Effect === EFFECT.heal) {
            info.heal = Math.max(info.heal, lowEnd(base, Number(e.Variance)));
        } else if (e.Effect === EFFECT.energize && e.EffectMiscValue_0 === "0") {
            info.energize = Math.max(info.energize, lowEnd(base, Number(e.Variance)));
        }
    }
}

const out = [];
for (const item of items) {
    if (item.ClassID !== CONSUMABLE) continue;
    const spells = spellsByItem.get(item.ID);
    const s = sparseByID.get(item.ID);
    if (!spells || !s) continue;
    const info = { health: 0, mana: 0, periodic: 0, heal: 0, energize: 0, wellFed: false };
    for (const sp of spells) scan(sp, info);
    // Fields: health, mana, bandage, healthstone, healthPotion, manaPotion, wellFed, conjured
    const row = [0, 0, 0, 0, 0, 0];
    const name = s.Display_lang ?? "";
    if (name.startsWith("Deprecated")) continue; // removed from the game, no one carries them
    if (item.SubclassID === SUB.food) {
        row[0] = info.health;
        row[1] = info.mana;
    } else if (item.SubclassID === SUB.bandage) {
        row[2] = info.periodic;
    } else if (/Healthstone/.test(name)) { // English names are fine here: this runs offline
        row[3] = info.heal;
    } else if (item.SubclassID === SUB.potion) {
        row[4] = info.heal;
        row[5] = info.energize;
    }
    if (row.every(v => v === 0)) continue;
    const conjured = (Number(s.Flags_0) & ITEM_FLAG_CONJURED) !== 0;
    out.push({ id: Number(item.ID), name, row, wellFed: info.wellFed, conjured });
}
out.sort((a, b) => a.id - b.id);

const lines = out.map(({ id, name, row, wellFed, conjured }) =>
    `    [${id}] = { ${[...row, wellFed, conjured].join(", ")} }, -- ${name}`);
const lua = `-- Generated by tools/gen-data.js from ${PRODUCT}; do not edit by hand.
-- itemID = { health, mana, bandage, healthstone, healthPotion, manaPotion, wellFed, conjured }
local _, ns = ...
ns.DATA = {
${lines.join("\n")}
}
`;
await Bun.write(new URL("../Data.lua", import.meta.url), lua);
console.log(`wrote ${out.length} items to Data.lua`);
