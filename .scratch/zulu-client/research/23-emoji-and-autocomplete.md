# Compose autocomplete and the complete emoji set

Research for issue `23-compose-autocomplete.md`. Sources are the official API docs at
`https://zulip.com/api/`, the help center at `https://zulip.com/help/`, the `zulip/zulip`
repository (server `zerver/lib/`, web client `web/src/`), and `zulip/zulip-flutter`.
Researched 2026-09-22 against current `main`, cross-checked live against
`chat.zulip.org` (`zulip_feature_level` 511 at time of writing).

"FL" means Zulip server **feature level**, reported by `POST /api/v1/register` as
`zulip_feature_level`. Every version-gated claim names the level it landed at.

Anything I could not determine is listed in §14.

---

## 1. Answer up front

- **Fetch `server_emoji_data_url` and cache it.** It is a plain static JSON file on the
  server's own origin, **no authentication, CORS-open, ETag'd**, containing exactly one key
  `code_to_names`. 1883 codes / 3339 names on chat.zulip.org today. Do not ship a copy;
  the server rejects names it does not know. FL 140. Details in §2.
- **`emoji_code` for unicode emoji is dash-separated lowercase hex with every `U+FE0F`
  stripped.** `1f44d`, `2764` (not `2764-fe0f`), `0023-20e3`, `1f1fa-1f1f8`,
  `1f3c3-200d-2640-200d-27a1`. **Skin-tone variants do not exist** in Zulip's table at all.
  Details in §4.
- **Name resolution order is: active realm emoji → `zulip` → unicode name table → give up
  and render the literal text.** A realm emoji named `smile` shadows unicode `:smile:`.
  Details in §5.
- **The composer inserts `:emoji_name:` — the name, never the codepoint** — with a trailing
  space, and a leading space unless the `:` started the line. Details in §7.
- **Mention/link markup**: `#**channel**`, `#**channel>topic**`, `#**channel>topic@123**`,
  `@**Full Name**`, `@**Full Name|123**`, `@_**Full Name**`, `@*group name*`,
  `@_*group name*`, and wildcards `@**all**` / `@**everyone**` / `@**channel**` /
  `@**stream**` / `@**topic**`. Details in §8.
- **Names containing `` ` `` `>` `*` `&` `[` `]` or `$$` cannot be expressed in this syntax
  at all** — the web client detects that and falls back to a plain markdown link. This is a
  real correctness trap; details in §8.4.
- **Ranking is not "prefix first" alone, and it is two-stage.** Match quality puts a result
  in a bucket; a per-type relevance comparator orders ties *inside* the bucket —
  subscription and recency for people, pinned/active/traffic for channels, a popularity list
  for emoji. Web does this with a six-bucket triage plus lazy getters (§10); zulip-flutter
  does it with an integer `rank` plus a stable bucket sort (§11), which is the cleaner model
  to port. **Copy flutter's emoji rank table (§11.4) — it is exactly the "realm custom emoji
  first" behaviour the ticket wants, and it makes the picker and the `:` autocomplete the
  same code.**
- **The two official clients disagree in places.** Side-by-side table in §11.10.

---

## 2. `server_emoji_data_url`

### 2.1 Where it comes from

`POST /register` sets it in the `realm` fetch-event block:

```python
state["server_emoji_data_url"] = emoji.data_url()
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/events.py> (`fetch_initial_state_data`)

```python
def data_url() -> str:
    # This bakes a hash into the URL, which looks something like
    # static/webpack-bundles/files/64.0cdafdf0b6596657a9be.png
    # This is how Django deals with serving static files in a cacheable way.
    # See PR #22275 for details.
    return staticfiles_storage.url("generated/emoji/emoji_api.json")
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/emoji.py>

So it is a **Django staticfiles URL**, content-hashed in production by
`ManifestStaticFilesStorage`. It is relative to the server (`/static/generated/emoji/...`)
unless the deployment sets a `STATIC_URL` pointing at a CDN. **Resolve it against the realm
URL and do not hardcode the path.**

### 2.2 Feature level

> **Feature level 140**
> * [`POST /register`](/api/register-queue): Added string field `server_emoji_data_url`
>   to the response.

— <https://github.com/zulip/zulip/blob/main/api_docs/changelog.md>

FL 140 is Zulip 6.0. The key is present only if `realm` is in `fetch_event_types`.
For older servers there is no fallback endpoint; you would have to ship a bundled table
(§14).

### 2.3 Authentication: none

Verified live, no credentials:

```
$ curl -sSI https://chat.zulip.org/static/generated/emoji/emoji_api.json
HTTP/2 200
content-type: application/json
last-modified: Sat, 18 Oct 2025 03:45:13 GMT
etag: W/"68f30d49-fb8a"
access-control-allow-origin: *
```

This matches the OpenAPI text: *"The HTTP response at that URL will have appropriate HTTP
caching headers, such any HTTP implementation should get a cached version if emoji haven't
changed since the last request."*
— <https://github.com/zulip/zulip/blob/main/zerver/openapi/zulip.yaml> (register response,
`server_emoji_data_url`)

For Zulu: a plain `URLSession` GET with `ETag`/`If-None-Match`, no `Authorization` header.

### 2.4 What the file actually contains

Downloaded from chat.zulip.org, 64 KB:

```json
{
  "code_to_names": {
    "0023-20e3": ["hash"],
    "1f44d":     ["+1", "thumbs_up", "like"],
    "1f1fa-1f1f8": ["flag_united_states"],
    "1f3c3-200d-2640-200d-27a1": ["woman_running_facing_right"],
    "1f426-200d-1f525": ["phoenix", "ascension", "emerge", "firebird", "glory",
                         "immortal", "rebirth", "reincarnation", "reinvent",
                         "renewal", "revival", "revive", "rise", "transform"]
  }
}
```

Measured shape of the live file:

| property | value |
|---|---|
| top-level keys | exactly one: `code_to_names` |
| distinct emoji codes | 1883 |
| distinct names | 3339 |
| names per code | 1 → 1204 codes, 2 → 367, 3 → 120, … max 14 |
| hex case | lowercase only |
| codes containing `fe0f` | **zero** |
| codes containing a skin-tone modifier (`1f3fb`–`1f3ff`) | **zero** |

**The first name in each array is the canonical name.** The OpenAPI description states it
(*"with the canonical name for the emoji always appearing first"*) and I verified it
mechanically: for all 1883 codes, `code_to_names[c][0]` equals the server's
`codepoint_to_name[c]` from `emoji_codes.json`. Zero mismatches.

### 2.5 The sibling file `emoji_codes.json` (do not depend on it)

`/static/generated/emoji/emoji_codes.json` is also served unauthenticated and has more:
`names`, `name_to_codepoint`, `codepoint_to_name`, `emoji_catalog`, `emoticon_conversions`.
It is the **web app's internal** file. The build script says so explicitly:

```python
# This is the more official API for mobile to fetch data about emoji.
# emoji_codes.json has a lot of goo, and we're creating this new file
# as a cleaner data format to move towards. ... So this is a temporary solution.
```
— <https://github.com/zulip/zulip/blob/main/tools/setup/emoji/build_emoji> (`generate_map_files`)

Only `emoji_api.json` is referenced from the API. Treat `emoji_codes.json` as
undocumented; the one thing worth lifting from it is the **category catalogue** for picker
sectioning (§6.3), which has no documented equivalent.

### 2.6 How the table is built (why names look the way they do)

`tools/setup/emoji/generate_emoji_names` produces `tools/setup/emoji/emoji_names.py` from:

- `emoji-datasource-google` (the iamcal/emoji-data package) — which emoji exist and their images
- `cldr-annotations-full` + `cldr-annotations-derived-full` — the human names
- `tools/setup/emoji/custom_emoji_names.py` — Zulip's hand-curated overrides

Rules, in order:

1. Zulip's curated entry wins outright if the code is in `CUSTOM_EMOJI_NAME_MAPS`.
2. Otherwise CLDR `tts` (exactly one value, the screen-reader label) becomes the
   **canonical name**; CLDR `default` becomes the **aliases**.
3. Aliases colliding with any canonical name are dropped.
4. Aliases claimed by more than one emoji are dropped from all non-curated emoji.
5. Non-ASCII names get an ASCII alias (`flag_türkiye` → `flag_turkiye`).

`cleanup_name` lowercases, maps spaces and dashes to `_`, strips punctuation, `&` → `and`.
— <https://github.com/zulip/zulip/blob/main/tools/setup/emoji/generate_emoji_names>

That is why newer emoji carry keyword-ish aliases: `1f34b-200d-1f7e9` →
`["lime", "acidity", "citrus", "garnish", "margarita", "mojito", "refreshing", "salsa",
"sour", "tangy", "tequila", "zest"]`. CLDR keywords are aliases, so **searching aliases
gives keyword search for free**.

---

## 3. `realm_emoji` in the register snapshot

### 3.1 Shape

`realm_emoji` is an **object keyed by stringified emoji id**, present if `realm_emoji` is in
`fetch_event_types`.

```json
"realm_emoji": {
  "1": {
    "id": "1",
    "name": "green_tick",
    "source_url": "/user_avatars/1/emoji/images/1.png",
    "still_url": null,
    "deactivated": false,
    "author_id": 5
  },
  "2": {
    "id": "2",
    "name": "animated_img",
    "source_url": "/user_avatars/1/emoji/images/animated_img.gif",
    "still_url": "/user_avatars/1/emoji/images/still/animated_img.png",
    "deactivated": false,
    "author_id": 3
  }
}
```
— <https://github.com/zulip/zulip/blob/main/zerver/openapi/zulip.yaml> (`RealmEmoji` schema
and the `/register` example)

| field | type | notes |
|---|---|---|
| `id` | string | Same as the map key. **This is the `emoji_code` for `reaction_type: "realm_emoji"`.** |
| `name` | string | The `:name:` shortcode. |
| `source_url` | string | Path **relative to the realm URL**. |
| `still_url` | string \| null | Non-null only for animated emoji; first frame. Optional at FL 97, mandatory-but-nullable at FL 113. |
| `deactivated` | bool | See §3.2. |
| `author_id` | int \| null | FL 7; previously an `author` object. |

Server-side TypedDict:

```python
class EmojiInfo(TypedDict):
    id: str
    name: str
    source_url: str
    deactivated: bool
    author_id: int | None
    still_url: str | None
```
— <https://github.com/zulip/zulip/blob/main/zerver/models/realm_emoji.py>

**`:zulip:` is not in `realm_emoji`.** The client must synthesize it. The web client does:

```ts
const zulip_emoji = {
    id: "zulip",
    emoji_name: "zulip",
    emoji_url: "/static/generated/emoji/images/emoji/unicode/zulip.png",
    still_url: null,
    is_realm_emoji: true,
    deactivated: false,
};
```
— <https://github.com/zulip/zulip/blob/main/web/src/emoji.ts>

### 3.2 Deactivated emoji

`deactivated: true` entries **stay in the snapshot** so existing reactions and rendered
messages still resolve. They must be excluded from the picker and from autocomplete.

- Server keeps them: `get_all_custom_emoji_for_realm` includes them; only
  `get_name_keyed_dict_for_active_realm_emoji` filters them out, and that is what markdown
  and new-reaction validation use.
- `check_emoji_request` raises *"This custom emoji has been deactivated."* for a new reaction.
- The uniqueness constraint is conditional:
  `UniqueConstraint(fields=["realm","name"], condition=Q(deactivated=False))` — **a name can
  be reused after deactivation**, so name is not a stable key; the id is.

— <https://github.com/zulip/zulip/blob/main/zerver/models/realm_emoji.py>,
<https://github.com/zulip/zulip/blob/main/zerver/lib/emoji.py>

### 3.3 Custom emoji image URLs need no auth

The path is `/user_avatars/<realm_id>/emoji/images/<basename><.ext>` (and
`.../images/still/<basename>.png` for the still frame), served by an explicitly unauthenticated
Django route:

```python
path("user_avatars/<path:path>", serve_local_avatar_unauthed, name="local_avatar_unauthed"),
```
— <https://github.com/zulip/zulip/blob/main/zproject/urls.py>

On the S3 backend they live in the public avatar bucket. Verified live: a real
`/user_avatars/...` file on chat.zulip.org returns 200 with no credentials. This is the
opposite of `/user_uploads/`, which needs the `Authorization` header.

`<basename>` is **a salted hash, not the id**:

```python
hash_key = settings.AVATAR_SALT.encode() + b":" + str(emoji_id).encode()
return "".join((hashlib.sha256(hash_key).hexdigest()[0:8], image_ext))
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/emoji.py> (`get_emoji_file_name`)

**Never construct the URL. Always use `source_url` / `still_url` verbatim**, resolved
against the realm URL. (The OpenAPI example showing `1.png` is a fixture, not the real shape.)

### 3.4 Custom emoji name validation

Two regexes exist and they disagree — worth knowing if you validate client-side:

- Model validator: `^[0-9a-z.\-_]+(?<![.\-_])$` (allows `.`)
  — <https://github.com/zulip/zulip/blob/main/zerver/models/realm_emoji.py>
- API-level `check_valid_emoji_name`: `^[0-9a-z\-_]+(?<![\-_])$` (no `.`)
  — <https://github.com/zulip/zulip/blob/main/zerver/lib/emoji.py>

Practically: lowercase ASCII letters, digits, `-`, `_`, must not end with `-` or `_`.
Note this is stricter than *unicode* emoji names, which can contain non-ASCII
(`flag_türkiye`, `gyōza`, `piña`, `yuèbǐng` are all real names in the live table).

### 3.5 The `realm_emoji` event

Three ops. Which you get depends on a **client capability**.

**Legacy (default): `realm_emoji` / `op: "update"`** — sends the *entire* emoji map every time.

```json
{"type": "realm_emoji", "op": "update",
 "realm_emoji": {"2": {"id": "2", "name": "my_emoji",
                       "source_url": "/user_avatars/2/emoji/images/2.png",
                       "deactivated": true, "author_id": 11}, ...},
 "id": 0}
```

**New at FL 491 (Zulip 12.0), if you send the `individual_emoji_changes` client capability
on `/register`:**

```json
{"type": "realm_emoji", "op": "add",
 "emoji": {"id": "2", "name": "my_emoji",
           "source_url": "/user_avatars/2/emoji/images/2.png",
           "still_url": null, "deactivated": false, "author_id": 11},
 "id": 0}
```

```json
{"type": "realm_emoji", "op": "update_one",
 "emoji_id": "2", "data": {"deactivated": true}, "id": 0}
```

> **Feature level 491**
> * `GET /events`: A new `individual_emoji_changes` client capability has been added.
>   Clients advertising this capability will not receive `realm_emoji/update` events with
>   the state of all emoji whenever there is a change; instead they will receive more
>   granular `realm_emoji/add` and `realm_emoji/update_one` events. […] Clients that do not
>   set the `individual_emoji_changes` client capability will continue to receive the legacy
>   `realm_emoji/update` event containing all emoji.

— <https://github.com/zulip/zulip/blob/main/api_docs/changelog.md>,
<https://github.com/zulip/zulip/blob/main/zerver/openapi/zulip.yaml>

`update_one`'s `data` currently only ever carries `deactivated`, but the schema is open to
more fields.

**Caution:** the OpenAPI prose calls the second op `realm_emoji/edit` in two places while
the `enum` says `update_one`. The `enum` and the example are authoritative; `update_one` is
what is on the wire.

For Zulu: declare `individual_emoji_changes` if the server is FL ≥ 491, but keep the
`op: "update"` full-replace handler — you will hit older servers.

---

## 4. How multi-codepoint emoji are encoded

The whole encoder is three functions:

```python
def unqualify_emoji(emoji: str) -> str:
    # ... an "unqualified" version of an emoji does not have an emoji
    # presentation selector. ...
    return emoji.replace("️", "")

def emoji_to_hex_codepoint(emoji: str) -> str:
    return "-".join(f"{ord(c):04x}" for c in emoji)

def hex_codepoint_to_emoji(hex: str) -> str:
    return "".join(chr(int(h, 16)) for h in hex.split("-"))
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/emoji_utils.py> (the entire file)

Rules that fall out of this:

- **dash-separated**, **lowercase hex**, **zero-padded to at least 4 digits**
  (`f"{ord(c):04x}"` — so `2764`, `00a9`; `1f600` is naturally 5).
- **Every `U+FE0F` variation selector is stripped.** `❤️` is `2764`, not `2764-fe0f`.
  This is the single most common way to get emoji codes wrong.
- ZWJ (`200d`), keycap (`20e3`) and regional indicators are **kept**.

Worked examples from the live table:

| kind | `emoji_code` | canonical name | glyph |
|---|---|---|---|
| simple | `1f44d` | `+1` | 👍 |
| de-qualified | `2764` | `heart` | ❤ |
| keycap | `0023-20e3` | `hash` | #⃣ |
| flag (regional-indicator pair) | `1f1fa-1f1f8` | `flag_united_states` | 🇺🇸 |
| ZWJ | `1f3c3-200d-2640` | `woman_running` | 🏃‍♀ |
| ZWJ ×2 | `1f3c3-200d-2640-200d-27a1` | `woman_running_facing_right` | 🏃‍♀‍➡ |
| new-style ZWJ | `1f426-200d-1f525` | `phoenix` | 🐦‍🔥 |

**Skin tones are not representable.** Zulip's generator deliberately excludes them:

```python
# We don't include the skin tones as emojis that one can search for on their own.
SKIN_TONE_EMOJI_CODES = ["1f3fb", "1f3fc", "1f3fd", "1f3fe", "1f3ff"]
```
— <https://github.com/zulip/zulip/blob/main/tools/setup/emoji/generate_emoji_names>

and no code in `emoji_api.json` contains a modifier (verified: zero hits across all 1883).
Skin-variation *images* are built into the sprite sheets, but the codes are absent from
`name_to_codepoint` / `codepoint_to_name`, so `check_emoji_request` rejects them:

```python
elif emoji_type == "unicode_emoji":
    if emoji_code not in codepoint_to_name:
        raise JsonableError(_("Invalid emoji code."))
    if name_to_codepoint.get(emoji_name) != emoji_code:
        raise JsonableError(_("Invalid emoji name."))
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/emoji.py>

**Consequence for Zulu: the emoji picker must not offer a skin-tone selector.** There is
nowhere to put the result.

**Rendering a `emoji_code` back to a glyph in Swift** is the inverse of
`hex_codepoint_to_emoji`: split on `-`, parse each as hex, `UnicodeScalar`, concatenate.
Because the codes are unqualified, some will render text-style unless you append `U+FE0F`
yourself for display — Zulip's own web client sidesteps this by rendering sprite images
rather than system glyphs, and zulip-flutter re-adds nothing (see §9).

---

## 5. Resolving an emoji name across the three reaction types

### 5.1 Name → (`emoji_code`, `reaction_type`)

This is the authoritative server order:

```python
def get_emoji_data(realm_id: int, emoji_name: str) -> EmojiData:
    realm_emoji_dict = get_name_keyed_dict_for_active_realm_emoji(realm_id)
    realm_emoji = realm_emoji_dict.get(emoji_name)

    if realm_emoji is not None:
        return EmojiData(emoji_code=str(realm_emoji["id"]), reaction_type=Reaction.REALM_EMOJI)

    if emoji_name == "zulip":
        return EmojiData(emoji_code=emoji_name, reaction_type=Reaction.ZULIP_EXTRA_EMOJI)

    if emoji_name in name_to_codepoint:
        return EmojiData(emoji_code=name_to_codepoint[emoji_name], reaction_type=Reaction.UNICODE_EMOJI)

    raise JsonableError(_("Emoji '{emoji_name}' does not exist"))
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/emoji.py>

**Active realm emoji win over unicode.** A realm emoji named `smile` shadows `:smile:`.
Mirror this precedence in Zulu's lookup or the picker and the composer will disagree with
the server.

### 5.2 (`reaction_type`, `emoji_code`) → something displayable

| `reaction_type` | `emoji_code` is | how to display |
|---|---|---|
| `unicode_emoji` | dash-separated hex codepoints | decode to a `String` and render as text (or your own sprite sheet) |
| `realm_emoji` | the stringified `RealmEmoji.id` | look up `realm_emoji[code]`, load `source_url` (or `still_url`) against the realm URL |
| `zulip_extra_emoji` | the emoji **name**, currently only `"zulip"` | fixed image `/static/generated/emoji/images/emoji/unicode/zulip.png` |

— <https://github.com/zulip/zulip/blob/main/zerver/openapi/zulip.yaml> (`ReactionType`)

Server-side constants:

```python
UNICODE_EMOJI = "unicode_emoji"
REALM_EMOJI = "realm_emoji"
ZULIP_EXTRA_EMOJI = "zulip_extra_emoji"
```
— <https://github.com/zulip/zulip/blob/main/zerver/models/messages.py> (`AbstractEmoji`)

with the definitive comment on `emoji_code`:

```python
# A string with the property that (realm, reaction_type,
# emoji_code) uniquely determines the emoji glyph.
```

Reaction uniqueness is `("user_profile", "message", "reaction_type", "emoji_code")` — never
`emoji_name`. (This matches the finding in `05-zulip-message-model.md` §8.)

There is **no `zulip_extra_emoji` registry on the server** — `"zulip"` is the only member
and is hardcoded in two places (markdown, and the web client's synthesized entry). Treat it
as a one-element set.

### 5.3 A resolution failure is not an error

If the name is unknown, markdown leaves the literal text alone:

```python
if name in active_realm_emoji:
    return make_realm_emoji(active_realm_emoji[name]["source_url"], orig_syntax)
elif name == "zulip":
    return make_realm_emoji("/static/generated/emoji/images/emoji/unicode/zulip.png", orig_syntax)
elif name in name_to_codepoint:
    return make_emoji(name_to_codepoint[name], orig_syntax)
else:
    return orig_syntax
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/markdown/__init__.py> (`class Emoji`)

Zulu should do the same when a reaction references an emoji it cannot resolve (e.g. a
reaction on a since-deleted realm emoji): render `:name:` as text rather than dropping it.

### 5.4 What `rendered_content` looks like

Since Zulu renders server HTML, these are the shapes to match:

```html
<!-- unicode -->
<span class="emoji emoji-1f44d" title="+1" role="img" aria-label="+1">:+1:</span>

<!-- realm custom emoji -->
<img src="/user_avatars/2/emoji/images/dbe43627.png" class="emoji"
     alt=":example_custom_emoji:" title="example custom emoji">

<!-- :zulip: -->
<img src="/static/generated/emoji/images/emoji/unicode/zulip.png" class="emoji"
     alt=":zulip:" title="zulip">
```
— <https://github.com/zulip/zulip/blob/main/api_docs/message-formatting.md> (§ Emoji),
<https://github.com/zulip/zulip/blob/main/zerver/lib/markdown/__init__.py>
(`make_emoji`, `make_realm_emoji`)

The unicode codepoint is in the class as `emoji-<emoji_code>`; the text content is the
literal `:name:` fallback. `title` is the name with underscores replaced by spaces.
Raw unicode emoji typed into the composer are normalized to the *same* span, so `👍` comes
back as `<span class="emoji emoji-1f44d">:+1:</span>`.

Messages sent before Zulip 1.9.2 lack `role` and `aria-label`; do not depend on them.
Zulip 12.0 (FL 436) recommends rendering single-paragraph emoji-only messages at ~2×.

---

## 6. Aliases and search

### 6.1 The alias model

Every unicode emoji has one canonical name (index 0 of `code_to_names[code]`) and zero or
more aliases. Aliases are **first-class**: `name_to_codepoint` maps canonical names *and*
aliases to the same code, and `check_emoji_request` accepts any of them. Sending
`emoji_name: "thumbs_up"` with `emoji_code: "1f44d"` is valid.

Distribution on chat.zulip.org: 1204 codes with 1 name, 367 with 2, 120 with 3, tailing to
one code with 14.

### 6.2 What the official clients actually match on

Web (`get_emoji_matcher` in <https://github.com/zulip/zulip/blob/main/web/src/typeahead.ts>):

- the query has spaces replaced with `_` and is lowercased
- it matches if the query **is the literal emoji character** (`parse_unicode_emoji_code(emoji.emoji_code) === query`), or
- `query_matches_string_in_order(query, emoji.emoji_name, "_", should_remove_diacritics)`

The predicate itself:

```ts
export function query_matches_string_in_order_assume_canonicalized(query, source_str, split_char, match_prefix?) {
    if (!query.includes(split_char) && !match_prefix) {
        // If query is a single token (doesn't contain a separator),
        // the match can be anywhere in the string.
        return source_str.includes(query);
    }
    // If there is a separator character in the query, then we
    // require the match to start at the start of a token.
    // (E.g. for 'ab cd ef', query could be 'ab c' or 'cd ef', but not 'b cd ef'.)
    return source_str.startsWith(query) || source_str.includes(split_char + query);
}
```
— <https://github.com/zulip/zulip/blob/main/web/src/typeahead.ts>

So for emoji (`split_char = "_"`): a query with **no** underscore is a plain **substring
match anywhere** in the name; a query **with** an underscore must start at the name start or
at an underscore boundary. Case-insensitive. Diacritics are stripped from the *source* only
when the query itself has none — `remove_diacritics(s) = s.normalize("NFKD").replaceAll(/\p{M}/gu, "")`.

The emoji **picker** uses a different, looser filter — `query.split(" ")` and every term must
be an `includes()` substring of the alias — but then sorts with the same
`typeahead.sort_emojis`.
— <https://github.com/zulip/zulip/blob/main/web/src/emoji_picker.ts> (`filter_emojis`)

**Recommendation for Zulu:** index every name (canonical + alias) → code, search across all
of them, but display the canonical name. Because CLDR keywords become aliases, this gives
"celebration" → 🎉 style search with no extra data.

### 6.3 Categories for the picker

There is **no documented API** for emoji categories. The undocumented `emoji_codes.json`
carries `emoji_catalog`, a map of category → ordered code list, generated by
`generate_emoji_catalog` sorting by the iamcal `sort_order`. On chat.zulip.org today:

| category | codes |
|---|---|
| Smileys & Emotion | 169 |
| People & Body | 386 |
| Animals & Nature | 159 |
| Food & Drink | 131 |
| Travel & Places | 195 |
| Activities | 85 |
| Objects | 264 |
| Symbols | 224 |
| Flags | 270 |

(JSON key order in the file is Symbols, Activities, Flags, Travel & Places, Food & Drink,
Animals & Nature, People & Body, Objects, Smileys & Emotion — **not** display order. The web
picker imposes its own order.)

Since this is undocumented and may vanish, the safer option for Zulu is to derive categories
from a bundled Unicode CLDR grouping keyed by codepoint, and fall back to a single flat
list. Flagged in §14.

### 6.4 Emoticons (`:)` → `:slight_smile:`)

Complete map, 12 entries:

```python
EMOTICON_CONVERSIONS = {
    ":)": ":slight_smile:",  "(:": ":slight_smile:",
    ":(": ":frown:",         "<3": ":heart:",
    ":|": ":neutral:",       ":/": ":confused:",
    ";)": ":wink:",          ":D": ":smile:",
    ":o": ":open_mouth:",    ":O": ":open_mouth:",
    ":p": ":stuck_out_tongue:", ":P": ":stuck_out_tongue:",
}
```
— <https://github.com/zulip/zulip/blob/main/tools/setup/emoji/emoji_setup_utils.py>
(also served as `emoticon_conversions` in `emoji_codes.json`)

This is a **server-side render-time** transform gated on the **sender's**
`translate_emoticons` user setting (`UserBaseSettings.translate_emoticons`, default
`False`). The stored `content` keeps the raw `:)`. Zulu does not need to implement it —
but it does explain why `:)` and `:P` are explicitly *excluded* from emoji autocomplete
(§10.2).

---

## 7. The markup the composer inserts for an emoji

`:emoji_name:` — the **name**, never the codepoint — plus a trailing space, and a leading
space unless the trigger `:` began the message or followed a space/newline:

```ts
if (beginning.lastIndexOf(":") === 0 ||
    beginning.charAt(beginning.lastIndexOf(":") - 1) === " " ||
    beginning.charAt(beginning.lastIndexOf(":") - 1) === "\n") {
    beginning = beginning.slice(0, -token.length - 1) + ":" + item.emoji_name + ": ";
} else {
    beginning = beginning.slice(0, -token.length - 1) + " :" + item.emoji_name + ": ";
}
```
— <https://github.com/zulip/zulip/blob/main/web/src/composebox_typeahead.ts>
(`content_typeahead_selected`)

The same string works for a realm emoji (`:party_parrot:`) and for `:zulip:` — the server
resolves the name at render time by the §5.1 precedence. The markdown syntax regex that
must match is:

```python
EMOJI_REGEX = r"(?P<syntax>:[\w\-\+]+:)"
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/markdown/__init__.py>

Note `\w` is Unicode-aware in Python, which is how `:flag_türkiye:` renders.

**The emoji picker should insert the same thing** when invoked from the composer, and should
send `(reaction_type, emoji_code, emoji_name)` when invoked as a reaction picker.

---

## 8. Autocomplete markup — the literal syntax

### 8.1 Channel mention

```
#**channel name**
```

Server regex:

```python
STREAM_LINK_REGEX = rf"""
                     {BEFORE_LINK_PRODUCING_MENTION_ALLOWED_REGEX}
                     \#\*\*                         # and after hash sign followed by double asterisks
                         (?P<stream_name>[^\*]+)    # stream name can contain anything
                     \*\*                           # ends by double asterisks
                    """
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/markdown/__init__.py>

Renders to `<a class="stream" data-stream-id="9" href="/#narrow/channel/9-announce">#announce</a>`.
`data-stream-id` is **deprecated** as of FL 319; parse the URL instead.
— <https://github.com/zulip/zulip/blob/main/api_docs/message-formatting.md>

### 8.2 Topic link

```
#**channel name>topic name**
```

and, to a specific message (FL 319, Zulip 10.0):

```
#**channel name>topic name@123**
```

```python
STREAM_TOPIC_LINK_REGEX = rf"""
                     {BEFORE_LINK_PRODUCING_MENTION_ALLOWED_REGEX}
                     \#\*\*
                         (?P<stream_name>[^\*>]+)    # stream name can contain anything except >
                         >                           # > acts as separator
                         (?P<topic_name>[^\*]*)      # topic name can be an empty string or contain anything
                     \*\*
                   """

STREAM_TOPIC_MESSAGE_LINK_REGEX = ... > (?P<topic_name>[^\*]*) @ (?P<message_id>\d+) \*\*
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/markdown/__init__.py>

The empty topic (`#**channel>**`) is valid from FL 346 and displays as
`realm_empty_topic_display_name` (from `/register`) wrapped in `<em>`.

### 8.3 User, silent, group, and wildcard mentions

```python
BEFORE_MENTION_ALLOWED_REGEX = r"(?<![^\s\'\"\(\{\[\/<])"

MENTIONS_RE = re.compile(
    rf"{BEFORE_MENTION_ALLOWED_REGEX}@(?P<silent>_?)(\*\*(?P<match>[^\*]+)\*\*)"
)
USER_GROUP_MENTIONS_RE = re.compile(
    rf"{BEFORE_MENTION_ALLOWED_REGEX}@(?P<silent>_?)(\*(?P<match>[^\*]+)\*)"
)

topic_wildcards = frozenset(["topic"])
stream_wildcards = frozenset(["all", "everyone", "stream", "channel"])
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/mention.py>

| what | literal syntax | rendered HTML |
|---|---|---|
| user mention | `@**Example User**` | `<span class="user-mention" data-user-id="31">@Example User</span>` |
| user mention, disambiguated | `@**Example User\|31**` | same |
| user mention, id only | `@**\|31**` | same |
| silent mention | `@_**Example User**` | `<span class="user-mention silent" data-user-id="31">Example User</span>` |
| user group | `@*support*` | `<span class="user-group-mention" data-user-group-id="17">@support</span>` |
| silent user group | `@_*support*` | `<span class="user-group-mention silent" data-user-group-id="17">support</span>` |
| channel wildcard | `@**all**` / `@**everyone**` / `@**channel**` / `@**stream**` | `<span class="user-mention channel-wildcard-mention" data-user-id="*">@channel</span>` |
| topic wildcard | `@**topic**` | `<span class="topic-mention">@topic</span>` |

— <https://github.com/zulip/zulip/blob/main/api_docs/message-formatting.md>
(§ Mentions and silent mentions)

The `|id` form is handled here:

```python
# For @**|id** and @**name|id** mention syntaxes.
id_syntax_match = re.match(r"(?P<full_name>.+)?\|(?P<user_id>\d+)$", name)
...
# For @**name|id**, we need to specifically check that
# name matches the full_name of user in mention_data.
# This enforces our decision that
# @**user_1_name|id_for_user_2** should be invalid syntax.
if full_name and user and user.full_name != full_name:
    return None, None, None
```
— <https://github.com/zulip/zulip/blob/main/zerver/lib/markdown/__init__.py> (`UserMentionPattern`)

**So `@**Name|id**` is only valid if the name still matches.** If someone renames, the
mention silently stops rendering. The web client only emits the `|id` form when the name is
ambiguous or collides with a wildcard word; copy that behaviour rather than always emitting
ids.

Rules worth carrying:

- The preceding character must be start-of-string, whitespace, or one of `' " ( { [ / <`
  (`BEFORE_MENTION_ALLOWED_REGEX`). A mid-word `@` does not become a mention.
- Names cannot contain `*` — `[^\*]+`. See §8.4.
- There is **no silent wildcard mention**. The docs say so explicitly.
- Mentioning a group requires membership in that group's `can_mention_group`; a message
  that violates it is rejected. **All** groups can be silently mentioned.
- A mention that matches nothing is silently left as plain text (no error).
- System groups (`role:administrators` etc.) can currently only be *silently* mentioned, and
  should be displayed by their description, not their `role:` API name.

### 8.4 The escaping trap

Neither syntax can express a name containing certain characters. The web client detects
this and emits an ordinary markdown link instead:

```ts
const invalid_stream_topic_regex = /[`>*&[\]]|(\$\$)/g;
```
— <https://github.com/zulip/zulip/blob/main/web/src/topic_link_util.ts>

```ts
if (will_produce_broken_stream_topic_link(stream_name)) {
    return get_fallback_markdown_link(stream_name);
}
return `#**${stream_name}**`;
```
— <https://github.com/zulip/zulip/blob/main/web/src/topic_link_util.ts> (`get_stream_link_syntax`)

Zulu must do the same, or channels named e.g. `design > ui` produce broken links.
Similarly `BEFORE_LINK_PRODUCING_MENTION_ALLOWED_REGEX` excludes `[` from the allowed
preceding characters (unlike the mention one) so that `[#**channel**](url)` does not
double-link.

---

## 9. What data the client needs, and which events keep it current

All of this is `POST /register` + the event queue — the same queue Zulu's GRDB store already
consumes (see `02-zulip-events-api.md`).

| autocomplete source | register key(s) | `fetch_event_types` | keeping it current |
|---|---|---|---|
| unicode emoji | `server_emoji_data_url` (→ fetch the JSON) | `realm` | never changes without a server upgrade; re-fetch when `zulip_version` changes, honour ETag |
| custom emoji | `realm_emoji` | `realm_emoji` | `realm_emoji` events (`update`, or `add`/`update_one` with `individual_emoji_changes`) — §3.5 |
| `:zulip:` | — (synthesize) | — | — |
| people | `realm_users`, `realm_non_active_users`, `cross_realm_bots` | `realm_user` | `realm_user` events (`add`, `remove`, `update`) |
| channels | `subscriptions`, `unsubscribed`, `never_subscribed` (subscription state) and `streams` (everything visible) | `subscription`, `stream` | `stream` events (`create`/`delete`/`update`) and `subscription` events (`add`/`remove`/`peer_add`/`peer_remove`/`update`) |
| user groups | `realm_user_groups` | `user_group` | `user_group` events (`add`, `remove`, `update`, `add_members`, `remove_members`, `add_subgroups`, `remove_subgroups`) |
| topics (for `#channel>`) | — | — | `GET /users/me/{stream_id}/topics` on demand |

— <https://github.com/zulip/zulip/blob/main/zerver/openapi/zulip.yaml> (`/register` response)

Notes on each:

- **`realm_users`** excludes deactivated users (they are in `realm_non_active_users`) and does
  not carry `is_active`. Guests with a restricted `can_access_all_users_group` get either a
  filtered list (with the `user_list_incomplete` client capability) or "Unknown user"
  placeholder objects.
- **`streams`** is every channel visible to the user, including web-public ones (FL 205) and
  archived ones (FL 378, with the `archived_channels` client capability). `subscriptions`
  additionally carries the per-user settings that matter for ranking: **`pin_to_top`**,
  `is_muted`, `color`, `subscribers`. `BasicChannel` carries **`is_recently_active`** and
  **`subscriber_count`**, which are useful ranking inputs the web client approximates with
  its own `stream_weekly_traffic`.
- **`realm_user_groups`** excludes deactivated groups unless the client sets
  `include_deactivated_groups` (FL 294). Each `UserGroup` has `name`, `description`, `id`,
  `members`, `direct_subgroup_ids`, `is_system_group`, and **`can_mention_group`** — the
  group-setting value that decides whether to offer it for a non-silent mention.
- **`recent_private_conversations`** (`fetch_event_types: recent_private_conversations`) is
  `[{max_message_id, user_ids}]` and is exactly the data the web client uses to rank people
  by DM recency (§10.3). Register for it.
- **Topics** have no register key. Fetch `GET /users/me/{stream_id}/topics` when the user
  types `#**channel>`; pass `allow_empty_topic_name=true` (FL 334) so the empty topic comes
  back as `""` rather than substituted.

---

## 10. How the web client actually ranks (zulip/zulip `web/src/`)

Path note: `web/shared/src/typeahead.ts` has moved to `web/src/typeahead.ts`.

### 10.1 Trigger detection — `tokenize_compose_str()`

Scans **backwards** from the cursor, capped:

```ts
/* Maximum channel name length + link syntax (#**>**) + some topic characters */
const MAX_LOOKBACK_FOR_TYPEAHEAD_COMPLETION = 60 + 6 + 20;   // = 86
```

```ts
case "#":
case "@":
case ":":
case "_":
    if (i === 0) { return s; }
    if (/[\s"'(/<[{]/.test(s[i - 1]!)) { return s.slice(i); }
    break;
```
— <https://github.com/zulip/zulip/blob/main/web/src/composebox_typeahead.ts>

**Answers the ticket's "does a trigger mid-word count" question: no.** The character before
the trigger must be start-of-input or one of whitespace, `"`, `'`, `(`, `/`, `<`, `[`, `{`.
Note this is *broader* than whitespace — `(@ali` opens the box.

There is also an abort based on what is to the *right* of the cursor:

```ts
// If the remaining content after the mention isn't a space or
// punctuation (or end of the message), don't try to typeahead; we
// probably just have the cursor in the middle of an
// already-completed object.
const terminal_symbols = ",.;?!()[]> \u{A0}\"'\n\t";
if (rest !== "" && !terminal_symbols.includes(rest[0]!)) {
    return [];
}
```

Slash commands only trigger at absolute index 0. Code fences must start a line.

### 10.2 Per-trigger open/close rules

| trigger | opens when | min chars after trigger | aborts |
|---|---|---|---|
| `:` emoji | token starts `:` | **1**, and it must be `+` or `a`–`z` | `/^:-.?$/` (blocks `:-p`), `/^:[^+a-z]?$/` (blocks bare `:`, `:P`, `:)`, `:1`), or a space right after `:` |
| `@` mention | token starts `@` | **0** — bare `@` lists everyone | token starts with a space, or still contains `*` after stripping a leading `**`/`*` |
| `@_` silent | token starts `@_` | 0 | as above |
| `#` channel | token starts `#` | **1** (`if (current_token.length === 1) return [];`) | space right after `#` |
| `>` topic | `#**channel**>` or `#**channel>partial` | 0 | token starts with a space |

```ts
// We don't want to match non-emoji emoticons such as :P or :-p
// Also, if the user has only typed a colon and nothing after, no need to match yet.
if (/^:-.?$/.test(current_token) || /^:[^+a-z]?$/.test(current_token)) { return []; }
// Don't autocomplete if there is a space following a ':'
if (current_token[1] === " ") { return []; }
```
— <https://github.com/zulip/zulip/blob/main/web/src/composebox_typeahead.ts> (`get_candidates`)

Topic regexes:

```ts
const stream_regex = /#\*\*([^*>]+)\*\*\s?>$/;                   // → "topic_jump"
const partial_stream_topic_regex = /#\*\*([^*>]+)>([^*\n]*)$/;   // #**channel>topic
const topic_shortcut_regex = /#(>)([^*\n]*)$/;                    // #>topic, current channel
```

Behavioural details worth copying:

- Pressing `>` while the channel list is open **force-selects** the highlighted channel
  (`compose_trigger_selection`), and `topic_jump` auto-selects with no user input.
- `hideAfterSelect: () => completing !== "stream"` — picking a channel deliberately keeps
  the box open so topics appear immediately.
- Escape during topic completion resolves to `#**channel** <typed text>` — channel link,
  space, the partial topic as plain text.
- `MAX_ITEMS = 50` (`web/src/bootstrap_typeahead.ts`); the composer uses all 50.
- The composer passes `matcher: () => true` and `sorter: items => items` — **all matching
  and ranking happens in `get_candidates`**, deliberately, to avoid O(realm) work in the
  typeahead widget. That is the same shape as the ticket's "a source supplies matches for a
  query and the text to insert".

### 10.3 The shared matching predicate and triage

`triage_raw()` puts each candidate in exactly one of six buckets, in this order:

```
1. entire string exact match
2. case-insensitive prefix match preserving diacritics in the query
3. prefix match with `query` exactly (case-sensitive)
4. prefix match case-insensitively
5. word-boundary prefix match case-insensitively
6. other
```
— <https://github.com/zulip/zulip/blob/main/web/src/typeahead.ts>

Word boundary is `[ _/-]` immediately before the query. `triage()` flattens 1–5 into
`matches` and 6 into `rest`. When a comparator is supplied, buckets 3 and 4 are merged and
sorted as one tier; 1, 2 and 5 are sorted separately.

The predicate is in §6.2. Summary: case-insensitive; **no query tokenization** — if the
query contains the type's `split_char` (`" "` for names/channels, `"_"` for emoji, `""` for
emails) the match must be anchored at a token start, otherwise it is a free substring match;
diacritics are stripped from the source only when the query has none.

There is also an order-independent variant `query_matches_string_in_any_order` (splits both
sides into words and greedily prefix-matches each query word to a distinct source word).

### 10.4 People (`@`)

Two layers.

**Layer A — bucket order** (`sort_recipients` in
<https://github.com/zulip/zulip/blob/main/web/src/typeahead_helper.ts>):

```ts
const getters = [
    {getter: best_users,  type: "users"},
    {getter: best_groups, type: "groups"},
    {getter: best_bots,   type: "users"},
    {getter: ok_users,    type: "users"},
    {getter: ok_bots,     type: "users"},
    {getter: worst_users, type: "users"},
    {getter: worst_groups,type: "groups"},
    {getter: worst_bots,  type: "users"},
];
```

Evaluated lazily; it stops once `max_num_items` is reached, so the expensive sorts for later
buckets never run. **Bots always rank below humans of the same match quality.**
`best` = name matched (triage buckets 1–5), `ok` = *email* matched among name non-matches,
`worst` = neither.

Two explicit design notes in that file:

```ts
// We don't push exact matches to the top, like we do with other
// typeaheads, because in open organizations, it's not uncommon to
// have a bunch of inactive users with display names that are just
// FirstName, ...
```
```ts
// We suggest only the first matching stream wildcard mention,
// irrespective of how many equivalent stream wildcard mentions match.
```

**Layer B — relevance inside a bucket** (`compare_people_for_relevance`):

1. Both real users **and composing to a channel** → `compare_users_for_streams`, whose own
   comment states the rule:
   ```ts
   // Sort order: subscribers > recency in topic/stream > direct message recency > alphabetical
   ```
   a. subscribed to the target channel first;
   b. `recent_senders.compare_by_recency(a, b, stream_id, topic)` — who spoke in this topic,
      then this channel, most recently;
   c. fall through to the DM rule below.
2. Both real users, **no channel context** → `compare_users_for_dms`:
   a. most recent DM with that user first (`get_latest_direct_message_id_with_user`); having
      any DM history beats having none;
   b. **only when the query is non-empty**, shorter `full_name` first;
   c. `localeCompare` on full name.
3. User vs wildcard → the user wins if subscribed to the channel, else if they have sent in
   this topic, else this channel, else if there is DM history; otherwise the wildcard wins.
4. Wildcard vs wildcard → source order of `broadcast_mentions()`.

Candidate-set construction (`get_person_suggestions`):

- exact full-name shortcut returns that one user immediately;
- muted users removed;
- two-pass: active users first, and **deactivated users only appear if active users don't
  fill the list**;
- DM-permission filtering is applied after the query filter, for cost.

So the ticket's open question — *"whether recency or subscription state matters"* — is
answered: **both, and subscription outranks recency.**

### 10.5 Channels (`#`)

```ts
export let sort_streams = <T extends StreamSubscription>(matches: T[], query: string): T[] => {
    const name_results = typeahead.triage(query, matches, (x) => x.name, compare_by_activity);
    const desc_results = typeahead.triage(query, name_results.rest, (x) => x.description, compare_by_activity);
    return [...name_results.matches, ...desc_results.matches, ...desc_results.rest];
};
```
— <https://github.com/zulip/zulip/blob/main/web/src/typeahead_helper.ts>

Name matches → **description matches** → the rest. `compare_by_activity` decides on the
first property where the two differ:

1. the channel currently selected in the compose box, always first;
2. not archived;
3. subscribed;
4. **only among subscribed channels**: `pin_to_top`, then recent activity, then not muted;
5. higher `stream_weekly_traffic`;
6. name, `strcmp`.

Candidate source is `stream_data.get_unsorted_subs_with_content_access()`; the matcher is
`query_matches_string_in_order(query, stream.name, " ", …)`.

Every input is available over the API: `pin_to_top` and `is_muted` from `subscriptions`,
and `is_recently_active`, `subscriber_count` and `stream_weekly_traffic` on `BasicChannel`:

> `stream_weekly_traffic` — The average number of messages sent to the channel per week, as
> estimated based on recent weeks, rounded to the nearest integer. If `null`, no information
> is provided on the average traffic. […] **Changes**: New in Zulip 8.0 (feature level 199).
> Previously, this statistic was available only in subscription objects.

— <https://github.com/zulip/zulip/blob/main/zerver/openapi/zulip.yaml> (`BasicChannel`)

### 10.6 Emoji (`:`)

```ts
const sorted_results_with_possible_duplicates = [
    ...perfect_emoji_matches,                          // obj.emoji_name === query
    ...popular_emoji_matches,                          // is_popular(obj)
    ...prioritise_realm_emojis(triage_results.matches),
    ...prioritise_realm_emojis(triage_results.rest),
];
```
— <https://github.com/zulip/zulip/blob/main/web/src/typeahead.ts> (`sort_emojis`)

with

```ts
query = query.replaceAll(" ", "_").toLowerCase();

function decent_match(name: string): boolean {
    const pieces = name.toLowerCase().split("_");
    return pieces.some((piece) => piece.startsWith(query));
}
const popular_set = new Set(frequently_used_emojis.map((e) => e.emoji_code));
function is_popular(obj: BaseEmoji): boolean {
    return !obj.is_realm_emoji && popular_set.has(obj.emoji_code) && decent_match(obj.emoji_name);
}
```

`prioritise_realm_emojis` puts **custom emoji ahead of unicode within each triage tier** —
which is the ticket's "realm custom emoji first" requirement, implemented as a stable
partition rather than a separate section. A final dedup drops unicode emoji whose code was
already seen and unicode emoji whose name is shadowed by a realm emoji.

The baseline popularity list, verbatim:

```ts
export const popular_emojis = [
    "1f44d", // +1
    "1f389", // tada
    "1f642", // slight_smile
    "2764",  // heart
    "1f6e0", // working_on_it
    "1f419", // octopus
];
```
— <https://github.com/zulip/zulip/blob/main/web/src/typeahead.ts>

At runtime this is replaced by `frequently_used_emojis`, computed **entirely client-side**
from reactions on messages the client already has —
`emoji_frequency.update_frequently_used_emojis_list()` →
`emoji_frequency_data.preferred_emoji_list()`, scoring each emoji by observed reactions,
ignoring reactions from muted users and in muted channels/topics.
— <https://github.com/zulip/zulip/blob/main/web/src/emoji_frequency.ts>

**There is no server API for emoji popularity.** Zulu can either ship the six-emoji
constant or compute its own frequency from the GRDB reaction table — the latter is what web
does and it is purely local.

### 10.7 User groups

In the `@` flow, groups are triaged by display name and **not relevance-sorted at all** —
they keep triage order, slotted between `best_users`/`best_bots` and
`worst_users`/`worst_bots`. Empty groups are skipped. The candidate set for mentions is
`user_groups.get_user_groups_allowed_to_mention()`, i.e. filtered by `can_mention_group`.
`role:members` additionally matches an alternate display string.
— <https://github.com/zulip/zulip/blob/main/web/src/typeahead_helper.ts> (`sort_recipients`)

Standalone `sort_user_groups()` is just triage + `strcmp` on name.

### 10.8 Wildcards offered

```ts
let wildcard_mention_array: string[] = [];
if (compose_state.get_message_type() === "private") {
    wildcard_mention_array = ["all", "everyone"];
} else if (compose_validate.stream_wildcard_mention_allowed()) {
    // TODO: Eventually remove "stream" wildcard from typeahead suggestions
    // once the rename of stream to channel has settled for users.
    wildcard_mention_array = ["all", "everyone", "stream", "channel", "topic"];
} else if (compose_validate.topic_wildcard_mention_allowed()) {
    wildcard_mention_array = ["topic"];
}
```
— <https://github.com/zulip/zulip/blob/main/web/src/composebox_typeahead.ts> (`broadcast_mentions`)

Secondary text: DMs → "Notify recipients"; `topic` → "Notify participants in this
conversation"; otherwise "Notify all channel subscribers".

Selecting `stream` inserts `@**channel**`, not `@**stream**`:

```ts
if (wildcard_match && user_id === undefined && full_name === "stream") { mention += "channel"; }
```
— <https://github.com/zulip/zulip/blob/main/web/src/people.ts> (`get_mention_syntax`)

Gating is `realm_can_mention_many_users_group` (FL 352, which also removed
`wildcard_mention_policy`; `realm_wildcard_mention_policy` remains in `/register` as a
deprecated approximation), applied only when the channel or topic exceeds
`wildcard_mention_threshold` participants.

Relevant feature levels:

| FL | change |
|---|---|
| 224 | `wildcard_mentioned` flag split into `stream_wildcard_mentioned` / `topic_wildcard_mentioned` |
| 229 | topic wildcards restricted by `wildcard_mention_policy` in large topics |
| 247 | `channel` added as a wildcard alias |
| 352 | `can_mention_many_users_group` replaces `wildcard_mention_policy` |

— <https://github.com/zulip/zulip/blob/main/api_docs/changelog.md>

### 10.9 What each selection inserts

All in `content_typeahead_selected()`
(<https://github.com/zulip/zulip/blob/main/web/src/composebox_typeahead.ts>). Every branch
deletes the trigger plus the token and appends a trailing space.

| selection | inserted |
|---|---|
| emoji | `:name: ` (leading space if needed — §7) |
| user | `@**Full Name** `, or `@**Full Name\|123** ` when the name is ambiguous or matches a wildcard word |
| silent user | `@_**Full Name** ` |
| user group | `@*group name* ` / `@_*group name* ` |
| wildcard | `@**all** ` etc.; `stream` → `@**channel** ` |
| channel | `#**name** `, or a markdown link if the name hits `invalid_stream_topic_regex` (§8.4) |
| topic jump (`>`) | rewrites the trailing `**` of the just-inserted channel link into `>` |
| topic | `#**channel>topic** `, or a markdown link on invalid characters |

Non-silent user mentions in DMs may be rewritten to silent by
`compose_validate.convert_mentions_to_silent_in_direct_messages`.

---

## 11. zulip-flutter — the closer model for Zulu

zulip-flutter is Zulip's own modern native client, and its structure is a better template
for Zulu than the web app's. Everything below is from
<https://github.com/zulip/zulip-flutter/tree/main>.

### 11.1 Architecture, in one paragraph

Two stages, always:

1. A **pre-sorted candidate list** built once at view-model init
   (`_usersByRelevance`, `_userGroupsByRelevance`, `_generateAllCandidates`).
2. `computeResults()` filters, assigns each result a small integer `rank`, and
   `bucketSort(unsorted, (r) => r.rank, numBuckets: N)`. `bucketSort`
   (`lib/model/algorithms.dart`) is documented as **stable**, so the pre-sort from stage 1
   is the tiebreak inside each rank bucket.

Rank beats relevance. Relevance only orders ties. This is a much easier model to port to
Swift than web's lazy-getter cascade, and it is O(n + buckets) instead of a comparator sort.

Search is cooperative-async: `filterCandidates` yields every 1000 candidates and calls
`shouldStop()`, which aborts when the query changed or all listeners went away
(`lib/model/autocomplete.dart`).

### 11.2 Trigger detection

Lookback bound (the analogue of web's 86):

```dart
  // To avoid spending a lot of time searching for autocomplete intents
  // in long messages, we bound how far back we look for the intent's start.
  int get _maxLookbackForAutocompleteIntent {
    return 1 // intent character, e.g. "#"
      + 2 // some optional characters e.g., "_" for silent mention or "**"
      // Per the API doc, maxChannelNameLength is in Unicode code points.
      // We walk the string by UTF-16 code units, and there might be one or two
      // of those encoding each Unicode code point.
      + 2 * store.maxChannelNameLength;
  }
```
— `lib/model/autocomplete.dart` (`ComposeContentAutocomplete`)

`maxChannelNameLength` is `max_stream_name_length` from `/register` — i.e. **server-driven,
not a constant**. Good idea for Zulu.

The scan walks backwards from the cursor; **any trigger character strictly inside the
selection aborts autocomplete**; otherwise the right-most matching trigger wins. All three
regexes are anchored with `$`, so the match must run exactly from the trigger to the cursor.

Mention:

```dart
  // What's likely to come before an @-mention: the start of the string,
  // whitespace, or punctuation. Letters are unlikely; in that case an email
  // might be intended. …
  const beforeAtSign = r'(?<=^|\s|\p{Punctuation})';

  // Characters that would defeat searches in full_name and emails, since
  // they're prohibited in both forms. …
  const fullNameAndEmailCharExclusions = r'\*`\\>"\p{Other}';
```

Emoji:

```dart
  // Similar reasoning as in _mentionIntentRegex.
  // Specifically forbid a preceding ":", though, to make "::" not a query.
  const before = r'(?<=^|\s|\p{Punctuation})(?<!:)';
  const nameCharacters = r'_\p{Letter}\p{Number}';
  // Recognize '+' only as part of '+1', the only emoji name that has it.
  // Reject on whitespace right after ':'; … Similarly reject starting with ':-',
  // which is common for emoticons.
```

Channel:

```dart
  const before = r'(?<=^|\s|\p{Punctuation})(?<![#@])';
```
so `##channel` queries `channel` and `@#user` queries `user`. Both `#foo` and `#**foo`
yield the raw query `foo` — **backspacing into a completed `#**channel**` re-opens the
box**, which web does not do.

Topic input has no trigger at all: the whole topic field is the query.

Differences from web worth noting: flutter allows a **non-collapsed selection** (the comment
says autocorrect and backspace programmatically expand the selection), uses Unicode property
classes rather than an ASCII whitelist for the preceding character, and has **no
right-of-cursor terminal-symbol abort**.

### 11.3 Mention ranking

Eight buckets, 0 best:

```dart
    if (nameMatchQuality != null) {
      return switch (nameMatchQuality) {
        NameMatchQuality.exact =>        1,
        NameMatchQuality.totalPrefix =>  2,
        NameMatchQuality.wordPrefixes => 3,
      };
    }
    assert(matchesEmail == true);
    return 7;
```
plus `_rankWildcardResult = 0` and groups at 4 / 5 / 6.

**wildcard → user exact → user total-prefix → user word-prefixes → group exact → group
total-prefix → group word-prefixes → user email-prefix.**
— `lib/model/autocomplete.dart` (`MentionAutocompleteQuery`)

Match qualities:

```dart
    if (normalizedName.startsWith(_normalized)) {
      if (normalizedName.length == _normalized.length) return NameMatchQuality.exact;
      else                                             return NameMatchQuality.totalPrefix;
    }
    if (_testContainsQueryWords(normalizedNameWords)) return NameMatchQuality.wordPrefixes;
    return null;
```
`wordPrefixes` means *all* the query's words prefix-match distinct name words **in order** —
strictly smarter than web's single word-boundary bucket. Normalization is
`toLowerCase()` → NFKD → strip `\p{M}`, with the comment *"Anders reports that this is what
web does"*.

`testUser` rejects inactive and muted users up front; email matching is
`deliveryEmail.startsWith(query)` only.

Relevance comparator (tiebreak inside a bucket):

```dart
  static int _compareByRelevance(User userA, User userB, {…}) {
    // TODO(#618): give preference to subscribed users first
    if (channelId != null) {
      final recencyResult = compareByRecency(userA, userB, …);
      if (recencyResult != 0) return recencyResult;
    }
    final dmsResult = compareByDms(userA, userB, store: store);
    if (dmsResult != 0) return dmsResult;
    final botStatusResult = compareByBotStatus(userA, userB);
    if (botStatusResult != 0) return botStatusResult;
    return compareByAlphabeticalOrder(userA, userB, store: store);
  }
```

**recency in topic → recency in channel → DM recency → non-bots before bots → alphabetical.**
Note the `TODO(#618)`: flutter **does not yet** rank subscribers first, which web does. So
on this one point web is ahead.

The `rank` field carries a long design commentary that is the single most useful paragraph
in either codebase for Zulu (abridged, verbatim):

```
  // Compare sort_recipients in Zulip web: …
  // Behavior we have that web doesn't and might like to follow:
  // - A "word-prefixes" match quality on user and user-group names …
  // Behavior web has that seems undesired, which we don't plan to follow:
  // - Ranking humans above bots, even when the bots have higher relevance
  //   and better match quality. If there's a bot participating in the
  //   current conversation and I start typing its name, why wouldn't we want
  //   that as a top result? Issue: https://github.com/zulip/zulip/issues/35467
  // - A "word-boundary" match quality … Our [NameMatchQuality.wordPrefixes] seems smarter.
  // - An "exact" match quality on emails: probably not worth its complexity. …
  // - Ranking some case-sensitive matches differently from case-insensitive
  //   matches. Users will expect a lowercase query to be adequate.
```

So: **do not copy web's case-sensitive bucket, and do not demote bots below a better
match.** Zulip's own newer client deliberately dropped both.

Wildcards: only **one** channel wildcard is ever offered (first available of
`all`, `everyone`, then `channel` if FL ≥ 247 else `stream`), `topic` only on channel
messages at FL ≥ 224, and **silent queries (`@_…`) get no wildcards at all**.

User groups: `store.activeGroups.where((g) => !g.isSystemGroup)`, sorted alphabetically,
matched on name only. Marked `TODO(#1776)` to switch to `can_mention_group` — so flutter is
*behind* web here; follow web and filter by `can_mention_group`.

### 11.4 Emoji ranking

Four match qualities and nine rank buckets:

```dart
enum EmojiMatchQuality {
  /// The query matches the whole emoji name (or the literal emoji itself).
  exact,
  /// The query matches a prefix of the emoji name, but not the whole name.
  prefix,
  /// The query matches starting at the start of a word in the emoji name,
  /// but not the start of the whole name.
  ///
  /// For example a name "ab_cd_ef" would match queries "c" or "cd_e"
  /// at this level, but not a query "b_cd_ef".
  wordAligned,
  /// The query matches somewhere in the emoji name,
  /// but not at the start of any word.
  other;
```

```dart
    return switch (matchQuality) {
      EmojiMatchQuality.exact       => 0,
      EmojiMatchQuality.prefix      => isPopular ? 1 : isCustomEmoji ? 3 : 5,
      EmojiMatchQuality.wordAligned => isPopular ? 2 : isCustomEmoji ? 4 : 6,
      EmojiMatchQuality.other       =>                 isCustomEmoji ? 7 : 8,
    };
```
— `lib/model/emoji.dart` (`EmojiAutocompleteQuery._rankResult`)

| rank | contents |
|---|---|
| 0 | exact, any type |
| 1 | popular, prefix |
| 2 | popular, word-aligned |
| 3 | **custom**, prefix |
| 4 | **custom**, word-aligned |
| 5 | unicode, prefix |
| 6 | unicode, word-aligned |
| 7 | custom, other |
| 8 | unicode, other |

`isCustomEmoji` covers **both** `realmEmoji` and `zulipExtraEmoji` — with the comment
*"The web implementation calls this condition `is_realm_emoji`, but its actual semantics is
it's true for the Zulip extra emoji too."*

**This table is the direct answer to the ticket's "realm custom emoji first".** An empty
query returns `prefix` for everything, so the picker with no query shows: the six popular
emoji, then all realm emoji + `:zulip:`, then every unicode emoji. That is exactly the
ordering the ticket asks for, and it falls out of the same ranking used by `:` autocomplete
— **one catalogue, one ranker, two surfaces**.

Matching (`EmojiAutocompleteQuery.match` / `_matchName`):

- query is `raw.replaceAll(' ', '_')` then lowercase + NFKD + strip marks;
- the **literal glyph** matches exactly, after trimming and stripping `U+FE0F` — flutter
  flags that web fails here (`_adjustQueryForExactUnicode`);
- name and **every alias** are tested, taking the best quality;
- a query without `_` may match anywhere in the name (`other`); a query containing `_`
  requires at least word-aligned.

Popular emoji are stored as **codes, names resolved from server data**:

```dart
  /// Codes for the popular emoji, in order; all are Unicode emoji.
  // This list should match web: …
    return [
      check('1f44d', '👍'),
      check('1f389', '🎉'),
      check('1f642', '🙂'),
      check('2764', '❤'),
      check('1f6e0', '🛠'),
      check('1f419', '🐙'),
    ];
```
— `lib/model/emoji.dart` (`EmojiStoreImpl._popularEmojiCodesList`)

That is the right shape for Zulu: hardcode codes, never names (names differ per server
version). Flutter does **not** implement web's usage-frequency reordering.

Candidate order in `_generateAllCandidates`: popular → all other server emoji → active realm
emoji (skipping any named `zulip`) → the `zulip_extra_emoji`. Name shadowing is handled by
building `namesOverridden = {…activeRealmEmoji names, 'zulip'}` and **removing those names
from the unicode emoji's name list**, dropping the unicode emoji entirely if it has no names
left.

### 11.5 Emoji display resolution

```dart
    switch (emojiType) {
      case ReactionType.unicodeEmoji:
        final parsed = tryParseEmojiCodeToUnicode(emojiCode);
        if (parsed == null) break;
        return UnicodeEmojiDisplay(emojiName: emojiName, emojiUnicode: parsed);

      case ReactionType.realmEmoji:
        final item = allRealmEmoji[emojiCode];
        if (item == null) break;
        // TODO we don't check emojiName matches the known realm emoji; is that right?
        return _tryImageEmojiDisplay(
          sourceUrl: item.sourceUrl, stillUrl: item.stillUrl, emojiName: emojiName);

      case ReactionType.zulipExtraEmoji:
        return _tryImageEmojiDisplay(
          sourceUrl: kZulipEmojiUrl, stillUrl: null, emojiName: emojiName);
    }
    return TextEmojiDisplay(emojiName: emojiName);
```
— `lib/model/emoji.dart` (`EmojiStoreImpl.emojiDisplayFor`)

Three display types — `UnicodeEmojiDisplay`, `ImageEmojiDisplay`, `TextEmojiDisplay` — and
**every failure path degrades to text**: unparseable code, unknown realm emoji id,
unresolvable URL. `TextEmojiDisplay` is also what the user's `emojiset: "text"` setting
produces, via `EmojiDisplay.resolve(userSettings)`. The text form inserts zero-width
characters so it doesn't get re-parsed:

```dart
String textEmojiForEmojiName(String emojiName) {
  return ':﻿${emojiName.replaceAll('_', '​_')}﻿:';
}
```

Note the lookup uses **`allRealmEmoji`** (including deactivated) for display but
**`activeRealmEmoji`** for the candidate list — the §3.2 split, implemented.

Code → glyph:

```dart
    return String.fromCharCodes(emojiCode.split('-')
      .map((hex) => int.parse(hex, radix: 16)));
```
— `lib/api/model/model.dart` (`tryParseEmojiCodeToUnicode`)

No `U+FE0F` is re-added. Rendering picks the platform font: Apple Color Emoji on iOS/macOS,
Noto Color Emoji elsewhere (`lib/widgets/emoji.dart`).

### 11.6 Fetching `server_emoji_data_url`

```dart
/// Fetch data from the URL described by [InitialSnapshot.serverEmojiDataUrl].
///
/// This request is unauthenticated, and the URL need not be on the realm.
/// The given [ApiConnection] is used for providing a `User-Agent` header
/// and for handling errors.
…
  return connection.send('fetchServerEmojiData', ServerEmojiData.fromJson,
    useAuth: false,
    http.Request('GET', emojiDataUrl));
```
— `lib/api/route/realm.dart`

**`useAuth: false`** — independent confirmation of §2.3. The same file warns that this
endpoint does not follow Zulip's `{code, msg, result}` error convention or return
`"result": "success"`, so generic API error handling misfires on it.

Scheduling (`lib/model/store.dart`, `UpdateMachine`): fire-and-forget right after `poll()`
starts, retried forever with `BackoffMachine(firstBound: 2s, maxBound: 2min)`. The rationale
is the best statement of the caching design anywhere:

```
  /// Effectively it's data that *would have* been in the [registerQueue]
  /// response, except that we pulled it out to its own endpoint as part of
  /// a caching strategy, because the data changes infrequently.
  ///
  /// Conveniently (a) this deferred fetch doesn't cause any fetch/event race,
  /// because this data doesn't get updated by events anyway (it can change
  /// only on a server restart); and (b) we don't need this data for displaying
  /// messages or anything else, only for certain UIs like the emoji picker,
  /// so it's fine that we go without it for a while.
```

Until it arrives, the picker shows only realm emoji and `:zulip:`
(`_serverEmojiData = null; // TODO(#974) maybe start from a hard-coded baseline`).

Flutter builds **no name → code index** — it keeps the server's code → names map and
linear-scans `allEmojiCandidates()`. With ~1900 codes and cooperative yielding that is fine;
in Swift a dictionary is cheaper and there is no reason to copy this.

Flutter's minimum supported server is `kMinSupportedZulipFeatureLevel = 371`
(`lib/api/core.dart`), which is why `serverEmojiDataUrl` is declared non-nullable with no
`TODO(server-N)` — there is no FL < 140 case to handle. Zulu should pick a floor the same way.

### 11.7 Realm emoji model and events

```dart
@JsonSerializable(fieldRename: FieldRename.snake)
class RealmEmojiItem {
  @JsonKey(name: 'id')
  final String emojiCode;
  final String name;
  final String sourceUrl;

  /// The non-animated version, if this is an animated emoji.
  ///
  /// As of 2025-10, this will be missing on animated emoji
  /// that were uploaded before Zulip Server 5 when this was added;
  /// see https://github.com/zulip/zulip/issues/36339 .
  final String? stillUrl;

  bool deactivated;
  final int? authorId;
```
— `lib/api/model/model.dart`

Note the JSON `id` **is** the `emoji_code`, and `deactivated` is deliberately mutable
because `update_one` patches it in place. The `still_url` caveat is a real-world one worth
copying: **animated emoji uploaded before Zulip 5 may have no `still_url`** despite the
schema calling it mandatory-but-nullable (zulip/zulip#36339; a backfill migration landed in
12.0).

All three event ops are handled:

```dart
  void handleRealmEmojiEvent(RealmEmojiEvent event) {
    switch (event) {
      case RealmEmojiAddEvent(:final emoji):
        allRealmEmoji[emoji.emojiCode] = emoji;

      case RealmEmojiUpdateOneEvent(:final emojiCode, :final data):
        final realmEmoji = allRealmEmoji[emojiCode];
        if (realmEmoji == null) return; // TODO(log)
        if (data.deactivated != null) realmEmoji.deactivated = data.deactivated!;

      case RealmEmojiUpdateEvent(:final realmEmoji):
        allRealmEmoji = realmEmoji;
    }
    _allEmojiCandidates = null;
  }
```
— `lib/model/emoji.dart`

`RealmEmojiUpdateEvent` (the legacy full-replace `op: "update"`) is marked
`// TODO(server-12): remove` — confirming §3.5's FL 491 transition.

### 11.8 What the compose box inserts

```dart
      case EmojiAutocompleteResult(:var candidate):
        replacementString = ':${candidate.emojiName}:';
      case UserMentionAutocompleteResult(:var userId):
        replacementString = '${userMention(user, silent: query.silent, users: store)} ';
      case WildcardMentionAutocompleteResult(:var wildcardOption):
        replacementString = '${wildcardMention(wildcardOption, store: store)} ';
      case UserGroupMentionAutocompleteResult(:final groupId):
        replacementString = '${userGroupMention(userGroup.name, silent: query.silent)} ';
      case ChannelLinkAutocompleteResult(:final channelId):
        replacementString = '${channelLink(channel, store: store)} ';
```
— `lib/widgets/autocomplete.dart` (`ComposeAutocomplete._onTapOption`)

**Emoji gets no trailing space** here (web adds one) and inserts the *canonical* name, not
the alias the user typed. Everything else gets one ASCII space.

```dart
/// An @-mention of an individual user, like @**Chris Bobbe|13313**.
String userMention(User user, {bool silent = false, UserStore? users}) {
  bool includeUserId = users == null
    || users.allUsers.where((u) => u.fullName == user.fullName)
         .take(2).length == 2;
  …
}

String _userMentionImpl({required bool silent, required String fullName, int? userId}) =>
  '@${silent ? '_' : ''}**$fullName${userId != null ? '|$userId' : ''}**';

String userGroupMention(String userGroupName, {bool silent = false}) =>
  '@${silent ? '_' : ''}*$userGroupName*';

String channelLink(ZulipStream channel, {required PerAccountStore store}) {
  if (_channelAvoidedCharsRegex.hasMatch(channel.name)) {
    return _channelFallbackMarkdownLink(channel, store: store);
  }
  return '#**${channel.name}**';
}

final _channelAvoidedCharsRegex = RegExp(r'[`>*&[\]]|\$\$');

const _channelAvoidedCharsReplacements = {
  '`': '&#96;', '>': '&gt;', '*': '&#42;', '&': '&amp;',
  '[': '&#91;', ']': '&#93;', r'$$': '&#36;&#36;',
};
```
— `lib/model/compose.dart`

The avoided-character set is **identical to web's** `invalid_stream_topic_regex` (§8.4), and
flutter additionally gives the HTML-entity escapes for the fallback link text. Copy both.

Wildcard insertion downgrades `channel` → `stream` on old servers:

```dart
    case WildcardMentionOption.stream:
      if (isChannelWildcardAvailable) {
        name = WildcardMentionOption.channel.canonicalString;
      }
```

Topic selection inserts **no markup** — it calls `controller.setTopic(option.topic)`,
because in flutter the topic is a separate field, not part of the message body.

### 11.9 Channel-link ranking

Three buckets (exact / totalPrefix / wordPrefixes), then a comparator chain:
composing-to channel → subscribed, ordered **pinned-unmuted > unpinned-unmuted >
pinned-muted > unpinned-muted** → recently active → weekly traffic → name. Archived
channels are excluded outright (`if (channel.isArchived) return null;`).
— `lib/model/autocomplete.dart` (`ChannelLinkAutocompleteQuery`)

Essentially web's `compare_by_activity` (§10.5) with archived channels dropped rather than
sunk, and with the pin/mute cross-product made explicit.

### 11.10 The two clients disagree — what to take

| question | web | flutter | take |
|---|---|---|---|
| case-sensitive match tier | yes | no | **flutter** — flutter's comment says users expect a lowercase query to be enough |
| bots below humans regardless of match | yes | no (relevance only) | **flutter** — see zulip/zulip#35467 |
| word matching | one word-boundary bucket | all query words prefix-match name words in order | **flutter** |
| subscribers ranked first for people | yes | no (`TODO(#618)`) | **web** |
| groups filtered by `can_mention_group` | yes | no (`TODO(#1776)`) | **web** |
| emoji usage-frequency reordering | yes, computed locally | no | optional; web's is purely client-side |
| realm emoji priority | stable partition within each tier | explicit rank buckets 3/4/7 | **flutter** — far easier to reason about |
| literal-glyph emoji query | broken (no trim/unqualify) | works | **flutter** |
| trailing space after emoji | yes | no | web's is nicer |

---

## 12. Recommendations for Zulu

Nothing here is a claim about Zulip; it is what the above implies for an iOS client.

**The source abstraction.** Both official clients validate the ticket's proposal: the box is
dumb (web passes `matcher: () => true, sorter: items => items`) and every source owns its own
matching and ranking. A Swift `AutocompleteSource` needs:

- `trigger: Character` and an "is this position valid" check (shared — §10.1, §11.2);
- `candidates(query:context:) -> [Suggestion]`, where `context` carries the target channel
  id and topic (people ranking needs both) and the compose mode (DM vs channel, for
  wildcards);
- per-suggestion `rank: Int` plus `insertionText` (already escaped — §8.4) and display fields.

A fourth source drops in without touching the box, because the trigger scanner and the
bucket sort are shared and only `candidates` is source-specific.

**Ranking shape.** Take flutter's: each source pre-sorts its candidate list once (on store
load / event), then per query assigns a small integer rank and runs a **stable** bucket sort.
O(n + buckets), no comparator, and the pre-sort is the tiebreak. Avoid web's lazy-getter
cascade — it exists to dodge work in a language without cheap sorting, and it makes the rules
hard to read.

**Trigger bounds should come from the server.** Flutter derives its lookback from
`max_stream_name_length` in `/register` rather than a constant. Do the same.

**Emoji catalogue, one store, two consumers.** The picker and the `:` source should share
one index:

- `code -> [names]` from `server_emoji_data_url` (§2);
- `name -> code` inverted from it, every alias included (§6.1);
- realm emoji from `realm_emoji`, keyed by id, excluding `deactivated` for input but
  retained for display (§3.2);
- a synthesized `zulip` entry (§3.1).

Ordering for both: flutter's nine-bucket rank table (§11.4). With an empty query it degrades
to "popular six, then realm emoji and `:zulip:`, then everything else" — the picker layout
the ticket asks for, with no separate code path. Skip the skin-tone selector entirely (§4).
Resolve every display failure to `:name:` text rather than dropping the emoji (§11.5).

**Fetch `server_emoji_data_url` off the critical path.** It is not needed to render messages,
only for the picker and `:` autocomplete, and it cannot change without a server restart —
so fire it after the event queue is up, retry with backoff, and let the picker show only
realm emoji until it lands (§11.6).

**Correctness items that are easy to get wrong**, ranked by how badly they bite:

1. Strip `U+FE0F` before hex-encoding a codepoint (§4).
2. Use `source_url` verbatim; do not build custom-emoji paths (§3.3).
3. Realm emoji shadow unicode emoji of the same name (§5.1).
4. Escape-check channel and topic names before emitting `#**...**` (§8.4).
5. Only emit `@**Name|id**` when the name is ambiguous, and never when the name might be
   stale — the server rejects a mismatch (§8.3).
6. Deactivated realm emoji stay in the snapshot and their names can be reused (§3.2). Look
   up display against *all* realm emoji; build the picker from *active* ones only (§11.5).
7. Animated realm emoji uploaded before Zulip 5 may have no `still_url` despite the schema
   (zulip/zulip#36339) — handle null (§11.7).

**Phone-specific** (the ticket's last bullet) — nothing in any Zulip source addresses a
suggestion box with the keyboard up; that is Zulu's own design problem. The only transferable
number is `MAX_ITEMS = 50`, which is a desktop scroll-list figure and almost certainly wrong
for a phone.

---

## 13. Quick reference

```
#**channel**                    channel link
#**channel>topic**              topic link
#**channel>topic@123**          message link           (FL 319)
#**channel>**                   empty-topic link       (FL 346)
@**Full Name**                  mention
@**Full Name|123**              disambiguated mention
@**|123**                       id-only mention
@_**Full Name**                 silent mention
@*group name*                   group mention
@_*group name*                  silent group mention
@**all** @**everyone**          channel wildcard
@**channel**                    channel wildcard       (FL 247)
@**stream**                     channel wildcard (legacy spelling)
@**topic**                      topic wildcard
:emoji_name:                    emoji
```

Emoji codes: dash-separated lowercase hex, `U+FE0F` stripped, no skin tones.
Reaction identity: `(reaction_type, emoji_code)`.

---

## 14. What I could not determine

- **Emoji categories.** No documented API. `emoji_catalog` in `emoji_codes.json` is the only
  server-provided grouping and that file is explicitly described as internal (§2.5). No
  documented display order for the categories either — the key order in the JSON is not it.
- **Pre-FL-140 servers.** There is no documented fallback for the unicode emoji table when
  `server_emoji_data_url` is absent. Fetching `/static/generated/emoji/emoji_codes.json`
  directly works today but is undocumented and unhashed.
- **Whether `still_url`/`source_url` can ever be absolute.** The schema says "path relative
  to the organization's URL", but the S3 backend returns a full public bucket URL from
  `get_public_upload_url`. I did not find a server-side normalization that guarantees the
  relative form. zulip-flutter resolves both through a generic `tryResolveUrl` against the
  realm URL, which handles either case — do the same.
- **Topic autocomplete ranking.** I confirmed the trigger mechanics and that topics come from
  `GET /users/me/{stream_id}/topics`, but not what the web client sorts them by beyond the
  shared triage. zulip-flutter's topic autocomplete is a different shape (a separate topic
  field, not `#channel>topic` in the body), so it does not answer the question either.
- **Whether the emoji-frequency heuristic is worth it.** Web computes `frequently_used_emojis`
  locally from observed reactions; flutter does not implement it at all. No source states
  which behaviour users prefer.
- **Nginx-level proof that `/user_avatars/` is unauthenticated.** The Django URL route
  (`serve_local_avatar_unauthed`) is explicit and the live check returns 200 with no
  credentials, but I did not find a matching `location /user_avatars` block in the packaged
  nginx config, so the exact production serving path is unconfirmed.
