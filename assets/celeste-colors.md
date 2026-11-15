# celeste colors

Each stop is listed with its offset, and each row names the points its gradient runs between in the 377-unit grid of the mark.

The mark is a circle 377 units across. The waves and the tail are drawn on circles whose diameters are Fibonacci numbers: 233 for both waves and for the flat run along the top of each fluke, 144 for each sweep, lobe, and waist of the tail, and 89 for its shoulders. The crescent is 44.5 units thick at its widest, the teal band is 27.5 units thick, and each gap is 10.5 units wide, which are half of 89, 55, and 21. Each band edge is concentric with the arc beside it, so a gap holds its width along its whole length. The horns sit 36 degrees above and below the center line, so the opening is one fifth of the circle, and the counter circle runs through both horns. The tail is mirrored about the center of that counter, 25 units right of the center of the mark. The stack sets the wordmark 34 units below the mark, with caps 34 units tall, and the wordmark spans the full width of the mark. The lockup scales the same wordmark to caps 89 units tall and centers it on the mark, 89 units to its right. The wordmark keeps 13.84:1 against the cream ground and the tail keeps at least 3.46:1, above the 3:1 that WCAG asks of graphics. The pale ends of the Ocean crescent and teal wave fall below that bar, at 1.59:1 and 1.17:1, and so does the flat teal wave, at 2.43:1.

## On Light

The color files are drawn for a light ground, and the mono files cover a dark one.

| Use | Stops |
|---|---|
| Crescent, radial from (47, 47) with a radius of 405 | `#86D3E8` at 0, `#3E9FC9` at 0.333, `#17669A` at 0.667, `#0D4A76` at 1 |
| Teal wave, from (9, 236) to (349, 330) | `#BDF1EA` at 0, `#86E0D6` at 0.333, `#3CC0B6` at 0.667, `#1A9AA0` at 1 |
| Blue wave, from (47, 273) to (254, 377) | `#5FB0D6` at 0, `#2E83B6` at 0.5, `#145A8C` at 1 |
| Tail, from (213, 139) to (213, 330) | `#3A8DC0` at 0, `#114B7C` at 0.5, `#072B4D` at 1 |
| Icon tile, top to bottom | `#FCF8F5` at 0, `#F0E8E0` at 1 |

The crescent and the blue wave darken where they pass under the teal wave, and the stem of the tail darkens where it meets the water. Each shade fades from the deepest stop of its shape at 42% opacity to nothing across 27.5 units, measured from the arc it follows.

| Use | Color |
|---|---|
| Ground | `#FCF8F5` |
| Wordmark | `#0D2A46` |

## Flat

The flat files fill each shape with one color.

| Use | Color |
|---|---|
| Crescent | `#036284` |
| Teal wave | `#09B5A9` |
| Blue wave | `#0486A6` |
| Tail | `#03395E` |
| Wordmark | `#0D2A46` |
| Ground | `#FCF8F5` |

## Mono

A mono file without a ground fills each shape with `currentColor`, so an inline copy takes the color of the text around it. A mono file for a dark ground fills with `#FFFFFF`, and one for a light ground fills with `#0A121A`. The mono files with a ground set the white artwork on `#0A121A`.

| Use | Stops |
|---|---|
| Icon tile, top to bottom | `#152330` at 0, `#0A121A` at 1 |
