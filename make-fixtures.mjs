import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

if (!process.argv[2]) throw new Error("Pass the existing Daymark schedule.ts path.");
const { buildWeek } = await import(pathToFileURL(process.argv[2]));
const slot = (start, end, allowed) => ({ start, end, ...(allowed ? { allowed } : {}) });
const w = (...days) => [...days, ...Array.from({ length: 7 - days.length }, () => [])];
const weekday = Array.from({ length: 5 }, () => [slot(540, 1020)]);
const split = Array.from({ length: 5 }, (_, i) => i === 2 || i === 4 ? [slot(470, 970)] : [slot(470, 970), slot(1140, 1290)]);
const fixtures = [
    ["default", w(...weekday), 3], ["split", w(...split, [], [slot(1140, 1290)]), 3],
    ["empty", w(), 6], ["tiny", w([slot(0, 2)]), 6],
    ["weighted", w(...split), 4, [23, 7, 17, 53]],
    ["one restricted", w([slot(450, 960, [2])], [slot(1140, 1290)]), 3],
    ["multiple restricted", w([slot(450, 960, [1,2])], [slot(450, 600, [0,2])], [slot(450, 900, [1])]), 3, [25, 35, 40]],
    ["restricted exceeds target", w([slot(0, 1440, [2])], [slot(30, 90, [0,1])], [slot(45, 90)]), 3, [40, 55, 5]],
];
let seed = 19001;
function rng(limit) { seed = (seed * 48271) % 2147483647; return seed % limit; }
for (let index = 0; index < 80; index++) {
    const count = 1 + rng(6);
    const shares = Array.from({ length: count }, () => 1 + rng(99));
    const work = Array.from({ length: 7 }, () => {
        const result = [];
        let start = rng(300);
        const windows = 1 + rng(4);
        for (let i = 0; i < windows && start < 1400; i++) {
            const end = Math.min(1440, start + 1 + rng(350));
            const eligible = Array.from({ length: count }, (_, colour) => colour).filter(() => rng(3));
            result.push(slot(start, end, index % 2 && eligible.length < count && eligible.length ? eligible : undefined));
            start = end + 1 + rng(70);
        }
        return result;
    });
    fixtures.push([`generated ${index}`, work, count, shares]);
}
writeFileSync(new URL("./schedule-fixtures.json", import.meta.url), JSON.stringify(fixtures.map(([name, work, count, shares]) =>
    ({ name, work, count, shares, expected: buildWeek(work, count, shares) }))));
