"""Codes photo : format, caractère aléatoire, normalisation."""

from collections import Counter
from itertools import pairwise

from services.codes import CODE_ALPHABET, CODE_LENGTH, format_code, generate_code, is_valid_code, normalize_code


def test_generated_code_has_expected_format():
    code = generate_code()
    assert len(code) == CODE_LENGTH == 12
    assert set(code) <= set(CODE_ALPHABET)
    assert is_valid_code(code)


def test_alphabet_has_no_ambiguous_characters():
    for character in "0O1I":
        assert character not in CODE_ALPHABET


def test_codes_are_unique_and_not_sequential():
    codes = [generate_code() for _ in range(5000)]
    assert len(set(codes)) == len(codes)
    assert codes != sorted(codes)
    same_prefix = sum(first[:4] == second[:4] for first, second in pairwise(codes))
    assert same_prefix < 5


def test_characters_are_uniformly_distributed():
    counts = Counter("".join(generate_code() for _ in range(5000)))
    expected = 5000 * CODE_LENGTH / len(CODE_ALPHABET)
    assert set(counts) == set(CODE_ALPHABET)
    assert all(0.75 * expected < count < 1.25 * expected for count in counts.values())


def test_normalize_accepts_human_input():
    assert normalize_code("a7k4-q92x-b3lm") == "A7K4Q92XB3LM"
    assert normalize_code(" A7K4 Q92X B3LM ") == "A7K4Q92XB3LM"
    assert normalize_code("A7K4Q92XB3LM") == "A7K4Q92XB3LM"


def test_normalize_rejects_invalid_codes():
    assert normalize_code("A7K4Q92XB3L") is None
    assert normalize_code("A7K4Q92XB3L0") is None
    assert normalize_code("../../etc/passwd") is None
    assert normalize_code("") is None
    assert normalize_code(None) is None
    assert normalize_code("A" * 500) is None


def test_format_code_groups_characters():
    assert format_code("A7K4Q92XB3LM") == "A7K4-Q92X-B3LM"
