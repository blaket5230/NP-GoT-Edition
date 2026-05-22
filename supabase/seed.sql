-- =============================================================================
-- Westeros (Neptune's Pride GOT) — Seed Data
-- Generated: 2026-05-21
-- Run after schema.sql. Populates static reference tables:
--   houses, castles, house_starting_castles, house_ai_personality
-- Note: council_seat_types does not exist as a table; seat names are enforced
--       via CHECK constraints on council_seats.seat.
-- =============================================================================


-- =============================================================================
-- HOUSES
-- =============================================================================

INSERT INTO houses (slug, name, words, color, seat_castle_slug, head_of_house) VALUES
  ('arryn',     'House Arryn',     'As High As Honor',          '#5d76b8', 'eyrie',         'Jon Arryn'),
  ('baratheon', 'House Baratheon', 'Ours Is The Fury',          '#f4d03f', 'storms_end',    'Robert Baratheon'),
  ('greyjoy',   'House Greyjoy',   'We Do Not Sow',             '#2c3e50', 'pyke',          'Balon Greyjoy'),
  ('lannister', 'House Lannister', 'Hear Me Roar',              '#c41e3a', 'casterly_rock', 'Tywin Lannister'),
  ('martell',   'House Martell',   'Unbowed, Unbent, Unbroken', '#d35400', 'sunspear',      'Doran Martell'),
  ('stark',     'House Stark',     'Winter Is Coming',          '#5a6b7a', 'winterfell',    'Eddard Stark'),
  ('targaryen', 'House Targaryen', 'Fire And Blood',            '#8b0000', 'dragonstone',   'Viserys Targaryen'),
  ('tully',     'House Tully',     'Family, Duty, Honor',       '#1f6fa3', 'riverrun',      'Hoster Tully'),
  ('tyrell',    'House Tyrell',    'Growing Strong',            '#2d8030', 'highgarden',    'Mace Tyrell');


-- =============================================================================
-- CASTLES
-- =============================================================================

-- ---- Crownlands ----
INSERT INTO castles (slug, name, region, tier, base_influence, map_x, map_y, ruling_house_slug) VALUES
  ('dragonstone',     'Dragonstone',    'Crownlands', 1, 49, 0.889433, 0.695187, 'targaryen'),
  ('red_keep',        'Red Keep',       'Crownlands', 1, 50, 0.67164,  0.744969, 'baratheon'),
  ('driftmark',       'Castle Driftmark','Crownlands', 2, 18, 0.834739, 0.702345, NULL),
  ('rooks_rest',      'Rook''s Rest',   'Crownlands', 2, 22, 0.78743,  0.689646, NULL),
  ('rosby',           'Rosby',          'Crownlands', 2, 22, 0.705678, 0.733713, NULL),
  ('stokeworth',      'Stokeworth',     'Crownlands', 2, 22, 0.692107, 0.725882, NULL),
  ('antlers',         'Antlers',        'Crownlands', 3, 12, 0.69151,  0.688893, NULL),
  ('ravenry',         'Blackcrown',     'Crownlands', 3, 12, 0.177035, 0.933175, NULL),
  ('breakwater',      'Breakwater',     'Crownlands', 3, 12, 0.660608, 0.507202, NULL),
  ('brownhollow',     'Brownhollow',    'Crownlands', 3, 12, 0.816739, 0.675802, NULL),
  ('dun_fort',        'Dun Fort',       'Crownlands', 3, 10, 0.742324, 0.713447, NULL),
  ('dyre_den',        'Dyre Den',       'Crownlands', 3, 10, 0.883202, 0.657014, NULL),
  ('hayford',         'Hayford',        'Crownlands', 3, 10, 0.658895, 0.73558,  NULL),
  ('high_tide',       'High Tide',      'Crownlands', 3, 12, 0.860355, 0.701152, NULL),
  ('hollard_castle',  'Hollard Castle', 'Crownlands', 3, 10, 0.73259,  0.691662, NULL),
  ('sharp_point',     'Sharp Point',    'Crownlands', 3, 12, 0.854817, 0.719642, NULL),
  ('aegonfort',       'Sow''s Horn',    'Crownlands', 3, 12, 0.663578, 0.704149, NULL),
  ('stonedance',      'Stonedance',     'Crownlands', 3, 12, 0.866586, 0.734852, NULL),
  ('sweetport_sound', 'Sweetport Sound','Crownlands', 3, 12, 0.859663, 0.680276, NULL),
  ('whispers',        'Whispers',       'Crownlands', 3,  8, 0.885434, 0.669469, NULL);

-- ---- Dorne ----
INSERT INTO castles (slug, name, region, tier, base_influence, map_x, map_y, ruling_house_slug) VALUES
  ('sunspear',      'Sunspear',      'Dorne', 1, 50, 0.884587, 0.959717, 'martell'),
  ('ghost_hill',    'Ghost Hill',    'Dorne', 2, 16, 0.86174,  0.934368, NULL),
  ('godsgrace',     'Godsgrace',     'Dorne', 2, 16, 0.763363, 0.951677, NULL),
  ('hellholt',      'Hellholt',      'Dorne', 2, 16, 0.559461, 0.962157, NULL),
  ('high_hermitage','High Hermitage','Dorne', 2, 16, 0.403736, 0.932541, NULL),
  ('kingsgrave',    'Kingsgrave',    'Dorne', 2, 16, 0.485919, 0.910451, NULL),
  ('starfall',      'Starfall',      'Dorne', 2, 16, 0.372969, 0.945704, NULL),
  ('yronwood',      'Yronwood',      'Dorne', 2, 16, 0.585286, 0.92497,  NULL),
  ('blackmont',     'Blackmont',     'Dorne', 3, 10, 0.401546, 0.920171, NULL),
  ('ghaston_grey',  'Ghaston Grey',  'Dorne', 3, 10, 0.675506, 0.916176, NULL),
  ('hellgate_hall', 'Hellgate Hall', 'Dorne', 3, 10, 0.551572, 0.94577,  NULL),
  ('lemonwood',     'Lemonwood',     'Dorne', 3, 10, 0.80497,  0.98447,  NULL),
  ('salt_shore',    'Salt Shore',    'Dorne', 3, 10, 0.750969, 0.981488, NULL),
  ('sandstone',     'Sandstone',     'Dorne', 3, 10, 0.459467, 0.966679, NULL),
  ('skyreach',      'Skyreach',      'Dorne', 3, 10, 0.478026, 0.930937, NULL),
  ('stinkwater',    'Stinkwater',    'Dorne', 3, 10, 0.861048, 0.971348, NULL),
  ('tor',           'Tor',           'Dorne', 3, 10, 0.719814, 0.934368, NULL),
  ('vaith',         'Vaith',         'Dorne', 3, 10, 0.722546, 0.963911, NULL),
  ('vultures_roost','Vulture''s Roost','Dorne',3, 10, 0.507216, 0.890171, NULL),
  ('wyl',           'Wyl',           'Dorne', 3, 10, 0.620071, 0.881335, NULL);

-- ---- Iron Islands ----
INSERT INTO castles (slug, name, region, tier, base_influence, map_x, map_y, ruling_house_slug) VALUES
  ('pyke',           'Pyke',           'Iron Islands', 1, 41, 0.22442,  0.627867, 'greyjoy'),
  ('hammerhorn',     'Hammerhorn',     'Iron Islands', 2, 14, 0.164549, 0.616374, NULL),
  ('harlaw_hall',    'Harlaw Hall',    'Iron Islands', 2, 14, 0.292051, 0.614141, NULL),
  ('hoare_castle',   'Hoare Castle',   'Iron Islands', 2, 14, 0.236408, 0.60083,  NULL),
  ('ten_towers',     'Ten Towers',     'Iron Islands', 2, 14, 0.284805, 0.610112, NULL),
  ('blacktyde',      'Blacktyde',      'Iron Islands', 3,  8, 0.247792, 0.591029, NULL),
  ('corpse_lake',    'Corpse Lake',    'Iron Islands', 3, 10, 0.182426, 0.615141, NULL),
  ('crow_spike_keep','Crow Spike Keep','Iron Islands', 3, 10, 0.153545, 0.609431, NULL),
  ('downdelving',    'Downdelving',    'Iron Islands', 3, 12, 0.181312, 0.620651, NULL),
  ('grey_garden',    'Grey Garden',    'Iron Islands', 3,  8, 0.279625, 0.602682, NULL),
  ('grey_glen',      'Grey Glen',      'Iron Islands', 3,  8, 0.799931, 0.581124, NULL),
  ('harridan_hill',  'Harridan Hill',  'Iron Islands', 3, 10, 0.28047,  0.616712, NULL),
  ('iron_holt',      'Iron Holt',      'Iron Islands', 3,  8, 0.22668,  0.620484, NULL),
  ('lordsport',      'Lordsport',      'Iron Islands', 3,  8, 0.206135, 0.625801, NULL),
  ('pebbleton',      'Pebbleton',      'Iron Islands', 3,  8, 0.203226, 0.61935,  NULL),
  ('sealskin_point', 'Sealskin Point', 'Iron Islands', 3, 10, 0.161163, 0.601864, NULL),
  ('shatterstone',   'Shatterstone',   'Iron Islands', 3,  8, 0.192439, 0.606902, NULL),
  ('volmark',        'Volmark',        'Iron Islands', 3,  8, 0.26266,  0.619905, NULL);

-- ---- North ----
INSERT INTO castles (slug, name, region, tier, base_influence, map_x, map_y, ruling_house_slug) VALUES
  ('moat_cailin',    'Moat Cailin',       'North', 1, 30, 0.506694, 0.477045, 'stark'),
  ('winterfell',     'Winterfell',        'North', 1, 50, 0.496097, 0.369638, 'stark'),
  ('barrow_hall',    'Barrow Hall',       'North', 2, 16, 0.36603,  0.44856,  NULL),
  ('castle_cerwyn',  'Castle Cerwyn',     'North', 2, 16, 0.498468, 0.379143, NULL),
  ('deepwood_motte', 'Deepwood Motte',    'North', 2, 14, 0.345356, 0.324802, NULL),
  ('dreadfort',      'Dreadfort',         'North', 2, 16, 0.705196, 0.357263, NULL),
  ('wolfs_den',      'Fishing Village',   'North', 2, 16, 0.131185, 0.405721, 'stark'),
  ('greywater_watch','Greywater Watch',   'North', 2, 16, 0.483574, 0.52872,  NULL),
  ('hornwood',       'Hornwood',          'North', 2, 14, 0.668732, 0.3973,   NULL),
  ('karhold',        'Karhold',           'North', 2, 14, 0.849761, 0.321469, NULL),
  ('last_hearth',    'Last Hearth',       'North', 2, 26, 0.684609, 0.291243, NULL),
  ('mormont_keep',   'Mormont Keep',      'North', 2, 16, 0.339321, 0.276975, NULL),
  ('torrhen_square', 'Torrhen''s Square', 'North', 2, 16, 0.392377, 0.403329, NULL),
  ('new_castle',     'White Harbor',      'North', 2, 10, 0.58857,  0.456489, NULL),
  ('deepdown',       'Deepdown',          'North', 3,  8, 0.876142, 0.257056, NULL),
  ('driftwood_hall', 'Driftwood Hall',    'North', 3,  8, 0.839072, 0.230511, NULL),
  ('flints_finger',  'Flint''s Finger',   'North', 3, 10, 0.242134, 0.504406, NULL),
  ('highpoint',      'Highpoint',         'North', 3, 10, 0.486626, 0.314469, NULL),
  ('ironrath',       'Ironrath',          'North', 3, 10, 0.454159, 0.331285, NULL),
  ('kingshouse',     'Kingshouse',        'North', 3, 10, 0.891532, 0.235773, NULL),
  ('oldcastle',      'Oldcastle',         'North', 3, 10, 0.6349,   0.491829, NULL),
  ('ramsgate',       'Ramsgate',          'North', 3, 12, 0.754375, 0.437826, NULL),
  ('widows_watch',   'Widow''s Watch',    'North', 3, 10, 0.871989, 0.446997, NULL);

-- ---- Reach ----
INSERT INTO castles (slug, name, region, tier, base_influence, map_x, map_y, ruling_house_slug) VALUES
  ('highgarden',       'Highgarden',      'Reach', 1, 48, 0.345905, 0.856823, 'tyrell'),
  ('hightower',        'Hightower',       'Reach', 1, 32, 0.230062, 0.920166, NULL),
  ('bitterbridge',     'Bitterbridge',    'Reach', 2, 18, 0.489657, 0.798412, NULL),
  ('brightwater_keep', 'Brightwater Keep','Reach', 2, 18, 0.236888, 0.885403, NULL),
  ('goldengrove',      'Goldengrove',     'Reach', 2, 18, 0.348905, 0.798747, NULL),
  ('horn_hill',        'Horn Hill',       'Reach', 2, 18, 0.349156, 0.88466,  NULL),
  ('longtable',        'Longtable',       'Reach', 2, 18, 0.478428, 0.814622, NULL),
  ('old_oak',          'Old Oak',         'Reach', 2, 18, 0.216498, 0.815374, NULL),
  ('starpike',         'Starpike',        'Reach', 2, 18, 0.426288, 0.869483, NULL),
  ('appleton',         'Appleton',        'Reach', 3, 12, 0.631452, 0.818542, NULL),
  ('ashford',          'Ashford',         'Reach', 3, 12, 0.499555, 0.841702, NULL),
  ('bandallon',        'Bandallon',       'Reach', 3, 12, 0.183959, 0.887546, NULL),
  ('cider_hall',       'Cider Hall',      'Reach', 3, 12, 0.432007, 0.832105, NULL),
  ('greenfield',       'Clegane Hall',    'Reach', 3, 12, 0.284847, 0.744021, NULL),
  ('coldmoat',         'Coldmoat',        'Reach', 3, 12, 0.197549, 0.796965, NULL),
  ('darkdell',         'Darkdell',        'Reach', 3, 10, 0.544087, 0.766672, NULL),
  ('dunstonbury',      'Dunstonbury',     'Reach', 3, 12, 0.300622, 0.868354, NULL),
  ('grassfield_keep',  'Grassfield Keep', 'Reach', 3, 12, 0.595746, 0.807441, NULL),
  ('grimston',         'Grimston',        'Reach', 3,  8, 0.221344, 0.849074, NULL),
  ('holyhall',         'Holyhall',        'Reach', 3, 12, 0.345683, 0.827976, NULL),
  ('honeyholt',        'Honeyholt',       'Reach', 3, 12, 0.246326, 0.901326, NULL),
  ('ivy_hall',         'Ivy Hall',        'Reach', 3, 12, 0.40267,  0.823318, NULL),
  ('new_barrel',       'New Barrel',      'Reach', 3, 12, 0.453021, 0.800114, NULL),
  ('wyndhall',         'Nunn''s Deep',    'Reach', 3, 12, 0.309537, 0.652871, NULL),
  ('red_lake',         'Red Lake',        'Reach', 3, 12, 0.271312, 0.786556, NULL),
  ('ring',             'Ring',            'Reach', 3, 12, 0.426069, 0.778748, NULL),
  ('spottswood',       'Spottswood',      'Reach', 3, 12, 0.837509, 0.980593, NULL),
  ('standfast',        'Standfast',       'Reach', 3, 12, 0.214421, 0.804339, NULL),
  ('sunhouse',         'Sunhouse',        'Reach', 3, 12, 0.284345, 0.974927, NULL),
  ('three_towers',     'Three Towers',    'Reach', 3, 12, 0.199814, 0.944512, NULL),
  ('tumbleton',        'Tumbleton',       'Reach', 3,  8, 0.584578, 0.771568, NULL),
  ('uplands',          'Uplands',         'Reach', 3, 12, 0.314386, 0.924011, NULL),
  ('whitegrove',       'Whitegrove',      'Reach', 3, 12, 0.457295, 0.854365, NULL);

-- ---- Riverlands ----
INSERT INTO castles (slug, name, region, tier, base_influence, map_x, map_y, ruling_house_slug) VALUES
  ('harrenhal',          'Harrenhal',          'Riverlands', 1, 30, 0.586909, 0.67149,  NULL),
  ('riverrun',           'Riverrun',           'Riverlands', 1, 50, 0.446628, 0.653255, 'tully'),
  ('the_twins',          'The Twins',          'Riverlands', 1, 30, 0.444702, 0.572371, NULL),
  ('acorn_hall',         'Acorn Hall',         'Riverlands', 2, 16, 0.475349, 0.677736, NULL),
  ('darry',              'Darry',              'Riverlands', 2, 16, 0.604696, 0.654767, NULL),
  ('maidenpool',         'Maidenpool',         'Riverlands', 2, 16, 0.708737, 0.675206, NULL),
  ('pinkmaiden_castle',  'Pinkmaiden Castle',  'Riverlands', 2, 16, 0.433958, 0.684759, NULL),
  ('raventree_hall',     'Raventree Hall',     'Riverlands', 2, 16, 0.544092, 0.664353, NULL),
  ('seagard',            'Seagard',            'Riverlands', 2, 16, 0.438728, 0.590325, NULL),
  ('stone_hedge',        'Stone Hedge',        'Riverlands', 2, 16, 0.520492, 0.654023, NULL),
  ('atranta',            'Atranta',            'Riverlands', 3, 10, 0.449381, 0.670561, NULL),
  ('lord_lychester_keep','Fairmarket',         'Riverlands', 3, 10, 0.504942, 0.620649, NULL),
  ('oldstones',          'Oldstones',          'Riverlands', 3, 10, 0.467557, 0.612334, NULL),
  ('riverspring',        'Oxcross',            'Riverlands', 3, 10, 0.244765, 0.712385, NULL),
  ('blackpool',          'Saltpans',           'Riverlands', 3,  8, 0.67966,  0.659698, NULL),
  ('castlewood',         'Stoney Sept',        'Riverlands', 3, 10, 0.473372, 0.709261, NULL),
  ('wayfarers_rest',     'Wayfarer''s Rest',   'Riverlands', 3, 10, 0.394467, 0.678188, NULL),
  ('whitewalls',         'Whitewalls',         'Riverlands', 3, 12, 0.638562, 0.68616,  NULL),
  ('willow_wood',        'Willow Wood',        'Riverlands', 3, 12, 0.34024,  0.659173, NULL);

-- ---- Stormlands ----
INSERT INTO castles (slug, name, region, tier, base_influence, map_x, map_y, ruling_house_slug) VALUES
  ('storms_end',   'Storm''s End',  'Stormlands', 1, 40, 0.812623, 0.820546, 'baratheon'),
  ('evenfall_hall','Evenfall Hall', 'Stormlands', 2, 14, 0.893494, 0.805791, NULL),
  ('griffins_roost','Griffin''s Roost','Stormlands',2,14,0.777228, 0.831294, NULL),
  ('nightsong',    'Nightsong',     'Stormlands', 2, 14, 0.458125, 0.881555, NULL),
  ('summerhall',   'Summerhall',    'Stormlands', 2, 14, 0.647621, 0.838742, NULL),
  ('amberly',      'Amberly',       'Stormlands', 3, 10, 0.838997, 0.844079, NULL),
  ('blackhaven',   'Blackhaven',    'Stormlands', 3,  8, 0.623369, 0.857151, NULL),
  ('broad_arch',   'Broad Arch',    'Stormlands', 3,  8, 0.671984, 0.865918, NULL),
  ('bronzegate',   'Bronzegate',    'Stormlands', 3,  8, 0.78559,  0.788463, NULL),
  ('crows_nest',   'Crow''s Nest',  'Stormlands', 3,  8, 0.747568, 0.84731,  NULL),
  ('fawnton',      'Fawnton',       'Stormlands', 3,  8, 0.651516, 0.795355, NULL),
  ('felwood',      'Felwood',       'Stormlands', 3,  8, 0.755937, 0.802575, NULL),
  ('gallowsgrey',  'Gallowsgrey',   'Stormlands', 3,  8, 0.512759, 0.862888, NULL),
  ('grandview',    'Grandview',     'Stormlands', 3,  8, 0.716919, 0.829571, NULL),
  ('greenstone',   'Greenstone',    'Stormlands', 3,  8, 0.897741, 0.8783,   NULL),
  ('harvest_hall', 'Harvest Hall',  'Stormlands', 3,  8, 0.56811,  0.847287, NULL),
  ('haystack_hall','Haystack Hall', 'Stormlands', 3,  8, 0.81409,  0.784111, NULL),
  ('mistwood',     'Mistwood',      'Stormlands', 3,  8, 0.825047, 0.874423, NULL),
  ('morne',        'Morne',         'Stormlands', 3, 10, 0.921421, 0.797322, NULL),
  ('parchments',   'Parchments',    'Stormlands', 3, 10, 0.872237, 0.78571,  NULL),
  ('rain_house',   'Rain House',    'Stormlands', 3, 10, 0.902828, 0.842584, NULL),
  ('stonehelm',    'Stonehelm',     'Stormlands', 3,  8, 0.719122, 0.865476, NULL),
  ('solar',        'Weeping Tower', 'Stormlands', 3, 12, 0.828509, 0.889931, NULL);

-- ---- Vale ----
INSERT INTO castles (slug, name, region, tier, base_influence, map_x, map_y, ruling_house_slug) VALUES
  ('eyrie',           'Eyrie',            'Vale', 1, 39, 0.714276, 0.608104, 'arryn'),
  ('gates_of_the_moon','Gates of the Moon','Vale', 2, 14, 0.705276, 0.618244, 'arryn'),
  ('hearts_home',     'Heart''s Home',    'Vale', 2, 14, 0.739636, 0.581396, NULL),
  ('longbow_hall',    'Longbow Hall',     'Vale', 2, 14, 0.863008, 0.567966, NULL),
  ('redfort',         'Redfort',          'Vale', 2, 14, 0.771583, 0.628394, NULL),
  ('runestone',       'Runestone',        'Vale', 2, 14, 0.900776, 0.604002, NULL),
  ('lonely_light',    'Baelish Keep',     'Vale', 3, 10, 0.919203, 0.548458, NULL),
  ('coldwater_burn',  'Coldwater Burn',   'Vale', 3,  8, 0.780913, 0.534224, NULL),
  ('gull_tower',      'Gull Tower',       'Vale', 3,  8, 0.887876, 0.618812, NULL),
  ('ironoaks',        'Ironoaks',         'Vale', 3,  8, 0.808923, 0.604494, NULL),
  ('newkeep',         'Newkeep',          'Vale', 3, 10, 0.66118,  0.546326, NULL),
  ('old_anchor',      'Old Anchor',       'Vale', 3,  8, 0.853905, 0.598914, NULL),
  ('hammerhal',       'Palisade Village', 'Vale', 3, 12, 0.611192, 0.625731, NULL),
  ('snakewood',       'Snakewood',        'Vale', 3,  8, 0.801397, 0.553607, NULL),
  ('strongsong',      'Strongsong',       'Vale', 3,  8, 0.641364, 0.580809, NULL),
  ('wickenden',       'Wickenden',        'Vale', 3,  8, 0.771046, 0.662978, NULL);

-- ---- Westerlands ----
INSERT INTO castles (slug, name, region, tier, base_influence, map_x, map_y, ruling_house_slug) VALUES
  ('casterly_rock', 'Casterly Rock', 'Westerlands', 1, 50, 0.217566, 0.724408, 'lannister'),
  ('ashemark',      'Ashemark',      'Westerlands', 2, 18, 0.283891, 0.677723, NULL),
  ('banefort',      'Banefort',      'Westerlands', 2, 18, 0.256397, 0.642757, NULL),
  ('castamere',     'Castamere',     'Westerlands', 2, 18, 0.256893, 0.683535, NULL),
  ('crakehall',     'Crakehall',     'Westerlands', 2, 18, 0.18335,  0.772931, NULL),
  ('golden_tooth',  'Golden Tooth',  'Westerlands', 2, 18, 0.342297, 0.690174, NULL),
  ('kayce',         'Kayce',         'Westerlands', 2, 18, 0.161704, 0.719067, NULL),
  ('tarbeck_hall',  'Tarbeck Hall',  'Westerlands', 2, 18, 0.20272,  0.744696, NULL),
  ('cornfield',     'Cornfield',     'Westerlands', 3, 12, 0.261105, 0.762894, NULL),
  ('crag',          'Crag',          'Westerlands', 3, 12, 0.256316, 0.665199, NULL),
  ('deep_den',      'Deep Den',      'Westerlands', 3, 12, 0.367214, 0.727336, NULL),
  ('faircastle',    'Faircastle',    'Westerlands', 3, 12, 0.202275, 0.689686, NULL),
  ('feastfires',    'Feastfires',    'Westerlands', 3, 12, 0.152034, 0.728942, NULL),
  ('hornvale',      'Hornvale',      'Westerlands', 3, 12, 0.360203, 0.7123,   NULL),
  ('sarsfield',     'Sarsfield',     'Westerlands', 3, 12, 0.279299, 0.704555, NULL),
  ('silverhill',    'Silverhill',    'Westerlands', 3, 12, 0.345937, 0.750102, NULL);


-- =============================================================================
-- HOUSE STARTING CASTLES
-- =============================================================================

INSERT INTO house_starting_castles (house_slug, castle_slug, is_seat) VALUES
  ('arryn',     'eyrie',           true),
  ('arryn',     'gates_of_the_moon', false),
  ('arryn',     'hearts_home',     false),
  ('arryn',     'longbow_hall',    false),
  ('arryn',     'runestone',       false),
  ('baratheon', 'bronzegate',      false),
  ('baratheon', 'felwood',         false),
  ('baratheon', 'griffins_roost',  false),
  ('baratheon', 'haystack_hall',   false),
  ('baratheon', 'storms_end',      true),
  ('greyjoy',   'hammerhorn',      false),
  ('greyjoy',   'harlaw_hall',     false),
  ('greyjoy',   'lordsport',       false),
  ('greyjoy',   'pyke',            true),
  ('greyjoy',   'ten_towers',      false),
  ('lannister', 'ashemark',        false),
  ('lannister', 'casterly_rock',   true),
  ('lannister', 'crakehall',       false),
  ('lannister', 'kayce',           false),
  ('lannister', 'sarsfield',       false),
  ('martell',   'ghost_hill',      false),
  ('martell',   'lemonwood',       false),
  ('martell',   'starfall',        false),
  ('martell',   'sunspear',        true),
  ('martell',   'yronwood',        false),
  ('stark',     'castle_cerwyn',   false),
  ('stark',     'deepwood_motte',  false),
  ('stark',     'hornwood',        false),
  ('stark',     'torrhen_square',  false),
  ('stark',     'winterfell',      true),
  ('targaryen', 'dragonstone',     true),
  ('targaryen', 'driftmark',       false),
  ('targaryen', 'high_tide',       false),
  ('targaryen', 'sharp_point',     false),
  ('targaryen', 'stonedance',      false),
  ('tully',     'pinkmaiden_castle', false),
  ('tully',     'raventree_hall',  false),
  ('tully',     'riverrun',        true),
  ('tully',     'seagard',         false),
  ('tully',     'stone_hedge',     false),
  ('tyrell',    'brightwater_keep', false),
  ('tyrell',    'cider_hall',      false),
  ('tyrell',    'goldengrove',     false),
  ('tyrell',    'highgarden',      true),
  ('tyrell',    'three_towers',    false);


-- =============================================================================
-- HOUSE AI PERSONALITY
-- =============================================================================

INSERT INTO house_ai_personality (house_slug, troop_bias, atk_bias, focus_override, expand_bias, flavor_note) VALUES
  ('arryn',     0.80, 1.40, 'grand_maester',  0, 'Eyrie knights. Very defensive, builds slowly.'),
  ('baratheon', 1.20, 0.80, 'hand',           2, 'Military hammer. High troops, attacks freely.'),
  ('greyjoy',   1.25, 0.75, 'lord_commander', 2, 'Iron raiders. Fast, aggressive, mobile.'),
  ('lannister', 1.05, 0.90, 'coin',           2, 'Wealthy aggressors. Gold first, then war.'),
  ('martell',   1.05, 1.10, 'whisperers',     0, 'Vipers. Patient and far-seeing, strike when ready.'),
  ('stark',     0.85, 1.30, 'lord_commander', 0, 'Honorable defenders. Hard to provoke, strong in place.'),
  ('targaryen', 1.00, 1.20, 'grand_maester',  0, 'Patient conquerors. Build first, then strike.'),
  ('tully',     0.90, 1.20, 'laws',           0, 'River lords. Defensive, expand along rivers.'),
  ('tyrell',    0.95, 1.00, 'coin',           0, 'Garden growers. Steady economy, gentle expansion.');
