"""Path corpus for the tagger golden test: hand-written edge cases plus seeded ones."""

import numpy as np

EDGE_CASES = [
    "/Samples/Drums/Kicks/Kick_01.wav",
    "/Samples/Drums/Kicks/BassDrum_Heavy.wav",
    "/Samples/Drums/Hats/Hi-Hat_Closed_03.wav",
    "/Samples/Drums/Hats/hihat open 2.wav",
    "/Samples/Drums/Hats/HH_OH_128.wav",
    "/Samples/Drums/Snares/SD_tight_snr.wav",
    "/Samples/Drums/Claps/clp-wide.aif",
    "/Samples/Drums/Percussion/Perc_Rim_01.flac",
    "/Samples/Synth/Leads/SynthLead_Saw_C3.wav",
    "/Samples/Synth/Pads/WarmPad_Am7.wav",
    "/Samples/Synth/Bass/808_Sub_Bass_F1.wav",
    "/Samples/Vocals/Vox/VoxChop_Female_Ah.wav",
    "/Samples/FX/Risers/riser_8bars_fx.wav",
    "/Samples/FX/Impacts/Impacts_Big_Boom.wav",
    "/Samples/Loops/Drum Loops/DrumLoop_120bpm_Dm.wav",
    "/Samples/Loops/Guitar/gtr_clean_arp_90.wav",
    "/Samples/Loops/Keys/Keys_Piano_Chords_pno.wav",
    "/Samples/Cymbals/Crash Cymbals/crash01.wav",
    "/Samples/Cymbals/cym_ride_bell.wav",
    "/Samples/Atmospheres/atm_Dark_Texture.wav",
    "/Volumes/Audio/Packs/Vol 2/Kits/Trap Kit/trap_kick_hard.wav",
    "/Volumes/Audio/Packs/New Samples Pack/Sounds/sound_effects_01.wav",
    "/Users/me/Music/Loopmasters/Techno Toolkit/Percussion Loops/PercLoop12.wav",
    "/a/b/c.wav",
    "/x/UPPER_CASE_NAME.WAV",
    "/x/camelCaseFileName.wav",
    "/x/snake_case_name_v2.wav",
    "/x/with-hyphen/multi-word-name_01.wav",
    "/x/digits123abc456/file99.wav",
    "/x/a/i/o.wav",
    "/x/Kicks/Kicks.wav",
    "/x/Snares/snares and claps.wav",
    "/x/boxes/glasses/buses.wav",
    "/x/Bass/bass_bass_bass.wav",
    "/x/Basses/bass.wav",
    "/x/ünïcode/Café_Ambience.wav",
    "/x/dots.in.name/file.v1.2.wav",
    "/x/.hidden/sample.wav",
    "/x/spaces in dir/and in name.wav",
    "relative/path/Kick_01.wav",
    "single_file_kick.wav",
]

_DIRS = ["Drums", "Kicks", "Snares", "Hats", "Claps", "Loops", "FX", "Vocals", "Synths",
         "Bass", "Pads", "Leads", "Percussion", "Textures", "One Shots", "Foley"]
_PACKS = ["Vol 1", "Vol 3", "Techno Toolkit", "LoFi_Dreams", "trapKit2", "House-Essentials",
          "Cinematic FX Pack", "808 Collection", "Analog_Drums_2020", "BreakBeats"]
_WORDS = ["kick", "snare", "hihat", "hh", "bd", "sd", "clap", "rim", "tom", "perc", "vox",
          "pad", "lead", "bass", "808", "fx", "sfx", "riser", "impact", "loop", "chop",
          "arp", "pluck", "stab", "crash", "ride", "shaker", "Hit", "Soft", "Hard", "Dry",
          "Wet", "Dark", "Bright", "Warm", "Punchy", "Long", "Short", "Distorted", "Clean",
          "Am", "Cm", "F#", "120", "90bpm", "01", "02", "v2", "final"]
_JOINERS = ["_", "-", " ", ""]
_EXT = [".wav", ".aif", ".flac", ".mp3"]


def build_paths(total: int = 200, seed: int = 20260522) -> list[str]:
    """Return ``total`` unique paths: all edge cases, then seeded random ones."""
    rng = np.random.default_rng(seed)
    paths = list(EDGE_CASES)
    seen = set(paths)
    while len(paths) < total:
        dirs = rng.choice(_DIRS, size=int(rng.integers(1, 4)), replace=False).tolist()
        if rng.random() < 0.6:
            dirs.insert(0, str(rng.choice(_PACKS)))
        joiner = str(rng.choice(_JOINERS))
        words = rng.choice(_WORDS, size=int(rng.integers(1, 5)), replace=False)
        name = joiner.join(str(w) for w in words) + str(rng.choice(_EXT))
        path = "/Samples/" + "/".join(dirs) + "/" + name
        if path not in seen:
            seen.add(path)
            paths.append(path)
    return paths
