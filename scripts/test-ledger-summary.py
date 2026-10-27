#!/usr/bin/env python3
"""No real model, microphone or private recording required. A loopback stub server stands in for LM Studio."""
import http.server
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location("ledger_summary", Path(__file__).with_name("ledger-summary.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ATLAS_FR = module.ATLAS / "fr.json"


def recording(*rows):
    """rows: (speaker label or None, text[, echo]) in order; returns a Recording dictionary."""
    names = sorted({row[0] for row in rows if row[0]})
    speakers = [{"id": str(uuid.uuid5(uuid.NAMESPACE_URL, name)).upper(), "label": name, "source": "system"} for name in names]
    ids = {speaker["label"]: speaker["id"] for speaker in speakers}
    segments = []
    for index, row in enumerate(rows):
        segment = {"id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"segment-{index}")).upper(), "start": index * 10.0, "end": index * 10.0 + 5,
                   "speakerID": ids.get(row[0]), "source": "system", "text": row[1]}
        if len(row) > 2 and row[2]:
            segment["echoSuspect"] = True
        segments.append(segment)
    return {"title": "Test", "speakers": speakers, "segments": segments}


def statement(turn, kind, text="Faire la chose.", owner=None, owner_turn=None, support=(), replaces=None, due=None):
    return {"turn": turn, "kind": kind, "text": text, "owner": owner, "owner_turn": owner_turn,
            "support_turns": list(support), "replaces": replaces, "due_text": due}


def ledger_for(*rows):
    return module.Ledger(module.build_turns(recording(*rows)))


def by_text(ledger, text):
    return next(item for item in ledger.items if item["text"] == text)


class WindowAndSchemaTests(unittest.TestCase):
    def test_windows_keep_complete_turns_and_refuse_oversized_turns(self):
        turns = module.build_turns(recording(*[("Ana", f"Phrase numéro {index} avec un peu de contenu.") for index in range(30)]))
        windows = module.split_windows(turns, 600)
        self.assertGreater(len(windows), 1)
        self.assertEqual([turn["sid"] for window in windows for turn in window], [turn["sid"] for turn in turns])
        self.assertTrue(all(len(module.compact(module.source_rows(window))) <= 600 for window in windows))
        long_turns = module.build_turns(recording(("Ana", "x" * 2_000)))
        with self.assertRaises(module.BudgetError):
            module.split_windows(long_turns, 1_000)

    def test_source_rows_keep_shipped_fields_and_label_unknown_voices(self):
        turns = module.build_turns(recording(("Ana", "Bonjour."), (None, "Je m'en charge.", True)))
        rows = module.source_rows(turns)
        self.assertEqual(list(rows[0]), ["id", "source", "speaker", "start", "text"])
        self.assertEqual(rows[1]["speaker"], module.UNIDENTIFIED)
        self.assertIs(rows[1]["echo_suspect"], True)
        self.assertEqual(module.participants(turns), ["Ana"])

    def test_extraction_schema_restricts_identifiers_and_owners(self):
        schema = module.extraction_schema(["S4", "S5"], ["Ana", "Bea"], ["L2"])
        properties = schema["properties"]["statements"]["items"]["properties"]
        self.assertEqual(list(properties), list(module.STATEMENT_FIELDS))
        self.assertEqual(properties["turn"]["enum"], ["S4", "S5"])
        self.assertEqual(properties["owner"]["anyOf"][0]["enum"], ["Ana", "Bea"])
        self.assertEqual(properties["replaces"]["anyOf"][0]["enum"], ["L2", "S4", "S5"])
        self.assertNotIn(module.UNIDENTIFIED, json.dumps(schema, ensure_ascii=False))

    def test_measured_prompt_versions_stay_reproducible(self):
        # Pinned before the first dev run; changing ledger-v1 would make its recorded results unreproducible.
        self.assertEqual(module.prompt_hash("ledger-v1"), "808d3ed816cfd549374298aa5ea772abdd6ba96ad2d425177d5c33d18706759f")
        self.assertEqual(module.PROMPT_HASH, module.prompt_hash(module.PROMPT_VERSION))
        self.assertNotEqual(module.prompt_hash("ledger-v1"), module.prompt_hash("ledger-v2"))

    def test_writer_cannot_emit_commitment_lists(self):
        for chapter in (False, True):
            schema = module.writer_schema(["S1"], chapter)
            self.assertEqual(set(schema["properties"]), {"details", "key_points", "overview"})
        self.assertEqual(module.writer_schema(["S1"], True)["properties"]["key_points"]["maxItems"], 0)
        self.assertNotIn("decisions", json.dumps(module.executive_schema(["S1"])))

    def test_parse_statements_validates_ids_kinds_and_length(self):
        valid = json.dumps({"statements": [statement("S1", "task", "Envoyer le devis [S1].", "Ana", "S1")]})
        parsed = module.parse_statements(valid, ["S1", "S2"], ["Ana"], [])
        self.assertEqual(parsed[0]["text"], "Envoyer le devis.")
        for broken in ({"statements": [statement("S9", "task")]},
                       {"statements": [statement("S1", "promise")]},
                       {"statements": [statement("S1", "task", owner="Zoé")]},
                       {"statements": [statement("S1", "task", replaces="L7")]},
                       {"statements": [statement("S1", "task", "x" * 301)]},
                       {"statements": [{"turn": "S1"}]},
                       {"statements": [], "decisions": []}):
            with self.assertRaises(module.InvalidResponse):
                module.parse_statements(json.dumps(broken), ["S1", "S2"], ["Ana"], [])
        with self.assertRaises(module.InvalidResponse):
            module.parse_statements("not json", ["S1"], ["Ana"], [])

    def test_writer_parsing_rejects_internal_identifiers_in_prose(self):
        content = {"details": [{"title": "Budget", "text": "Voir la parole S3 pour le détail.", "evidence_turns": ["S1"]}],
                   "key_points": [], "overview": "Résumé."}
        with self.assertRaises(module.InvalidResponse):
            module.parse_writing(json.dumps(content), ["S1"], False)
        content["details"][0]["text"] = "Le budget reste ouvert [S1]."
        self.assertEqual(module.parse_writing(json.dumps(content), ["S1"], False)["details"][0]["text"], "Le budget reste ouvert.")


class OwnerGroundingTests(unittest.TestCase):
    def test_self_commitment_is_a_task(self):
        ledger = ledger_for(("Ana", "Bea, tu peux appeler le fournisseur ?"), ("Bea", "Oui, je m'en charge."))
        ledger.add_window(0, [statement("S2", "task", "Appeler le fournisseur.", "Bea", "S2", ["S1"])], [], [])
        self.assertEqual((ledger.items[0]["section"], ledger.items[0]["owner"]), ("task", "Bea"))

    def test_assignment_without_heard_acceptance_stays_to_confirm(self):
        ledger = ledger_for(("Ana", "Bea s'occupera du fournisseur."), ("Cy", "Passons au budget."))
        ledger.add_window(0, [statement("S1", "task", "Appeler le fournisseur.", "Bea", None)], [], [])
        item = ledger.items[0]
        self.assertEqual((item["section"], item["owner_status"]), ("to_confirm", "assigned_by_other"))
        self.assertIn("acceptation non entendue", item["reason"])

    def test_third_party_assignment_accepted_by_assignee_is_valid(self):
        ledger = ledger_for(("Ana", "Bea, tu prends le fournisseur."), ("Bea", "D'accord."))
        ledger.add_window(0, [statement("S1", "task", "Appeler le fournisseur.", "Bea", "S2")], [], [])
        self.assertEqual((ledger.items[0]["section"], ledger.items[0]["owner"]), ("task", "Bea"))

    def test_quoted_first_person_speech_is_not_grounded_for_the_quoted_person(self):
        ledger = ledger_for(("Ana", "Bea va me dire : je m'en occupe."), ("Bea", "On verra."))
        ledger.add_window(0, [statement("S1", "task", "S'occuper du fournisseur.", "Bea", "S1")], [], [])
        item = ledger.items[0]
        self.assertEqual((item["section"], item["owner_status"]), ("to_confirm", "turn_mismatch"))

    def test_the_same_person_may_request_and_accept(self):
        ledger = ledger_for(("Ana", "Qui peut appeler le fournisseur ? Personne ? Bon, je le fais."))
        ledger.add_window(0, [statement("S1", "task", "Appeler le fournisseur.", "Ana", "S1", ["S1"])], [], [])
        self.assertEqual(ledger.items[0]["section"], "task")

    def test_unidentified_voice_and_echo_cannot_confirm_an_owner(self):
        ledger = ledger_for(("Ana", "Qui s'en charge ?"), (None, "Moi, je m'en charge."), ("Bea", "Je m'en charge.", True))
        ledger.add_window(0, [statement("S2", "task", "Préparer la salle.", "Ana", "S2"),
                              statement("S3", "task", "Ranger la salle.", "Bea", "S3")], [], [])
        self.assertEqual(by_text(ledger, "Préparer la salle.")["owner_status"], "unidentified_voice")
        self.assertEqual(by_text(ledger, "Ranger la salle.")["owner_status"], "echo_only")
        self.assertTrue(all(item["section"] == "to_confirm" for item in ledger.items))

    def test_non_commitment_kinds_never_keep_an_owner(self):
        ledger = ledger_for(("Ana", "Il faudra prévenir la compta."))
        ledger.add_window(0, [statement("S1", "unassigned_followup", "Prévenir la compta.", "Ana", "S1")], [], [])
        self.assertIsNone(ledger.items[0]["owner"])
        self.assertEqual(ledger.items[0]["model_owner"], "Ana")


class ReplacementTests(unittest.TestCase):
    def setUp(self):
        self.ledger = ledger_for(("Ana", "Bea, tu peux écrire le rapport ?"), ("Bea", "Oui, je l'écris pour jeudi."),
                                 ("Cy", "On n'a plus besoin du rapport de toute façon."), ("Bea", "Finalement je ne peux pas l'écrire."),
                                 ("Ana", "Cy pourrait reprendre le rapport."), ("Cy", "D'accord, je reprends le rapport."))
        self.ledger.add_window(0, [statement("S2", "task", "Écrire le rapport.", "Bea", "S2", ["S1"], due="pour jeudi")], [], [])

    def test_third_party_withdrawal_is_not_applied(self):
        self.ledger.add_window(1, [statement("S3", "withdrawn", "Abandonner le rapport.", None, None, replaces="L1")], ["L1"], [])
        task = self.ledger.items[0]
        self.assertEqual((task["status"], task["section"]), ("active", "task"))
        self.assertIn("non confirmé", task["notes"][0])
        self.assertEqual(self.ledger.items[1]["section"], "to_confirm")
        writing = {"overview": "Résumé.", "key_points": [], "details": []}
        result = module.summarize(self.ledger, list(self.ledger.turns.values()), writing)
        self.assertEqual([item["assignee_name"] for item in result["action_items"]], ["Bea"])
        self.assertEqual(result["follow_ups"][0]["kind"], "withdrawn")
        self.assertIn("Écrire le rapport. (pour jeudi) ; à vérifier : retrait évoqué par Cy (S3)", module.markdown(result))

    def test_owner_and_requester_withdrawals_are_applied(self):
        self.ledger.add_window(1, [statement("S4", "withdrawn", "Ne plus écrire le rapport.", "Bea", "S4", replaces="L1")], ["L1"], [])
        self.assertEqual(self.ledger.items[0]["status"], "withdrawn")
        requester = ledger_for(("Ana", "Bea, tu peux écrire le rapport ?"), ("Bea", "Oui."), ("Ana", "Finalement, laisse tomber le rapport."))
        requester.add_window(0, [statement("S2", "task", "Écrire le rapport.", "Bea", "S2", ["S1"])], [], [])
        requester.add_window(1, [statement("S3", "withdrawn", "Annuler le rapport.", None, None, replaces="L1")], ["L1"], [])
        self.assertEqual(requester.items[0]["status"], "withdrawn")

    def test_handover_requires_the_new_owner_acceptance(self):
        self.ledger.add_window(1, [statement("S5", "task", "Écrire le rapport.", "Cy", None, replaces="L1")], ["L1"], [])
        self.assertEqual(self.ledger.items[0]["status"], "active")
        self.ledger.add_window(2, [statement("S6", "task", "Écrire le rapport.", "Cy", "S6", ["S5"], replaces="L1")], ["L1"], [])
        self.assertEqual((self.ledger.items[0]["status"], self.ledger.items[0]["successor"]), ("superseded", "L3"))
        self.assertEqual((self.ledger.items[2]["section"], self.ledger.items[2]["owner"]), ("task", "Cy"))

    def test_correction_inside_one_window_supersedes_the_earlier_statement(self):
        ledger = ledger_for(("Ana", "Je livre le guide le 29 octobre."), ("Bea", "Très bien."), ("Ana", "Correction : un brouillon le 29 octobre."))
        ledger.add_window(0, [statement("S1", "task", "Livrer le guide.", "Ana", "S1", due="le 29 octobre"),
                              statement("S3", "task", "Livrer un brouillon du guide.", "Ana", "S3", replaces="S1", due="le 29 octobre")], [], [])
        self.assertEqual([item["status"] for item in ledger.items], ["superseded", "active"])

    def test_shared_support_turns_and_incompatible_kinds_do_not_replace(self):
        ledger = ledger_for(("Ana", "Bea, tu corriges le test ?"), ("Bea", "Je m'en charge."), ("Ana", "Moi, j'écris le guide."),
                            ("Ana", "On garde le pilote."))
        ledger.add_window(0, [statement("S2", "task", "Corriger le test.", "Bea", "S2", ["S1"]),
                              statement("S3", "task", "Écrire le guide.", "Ana", "S3", replaces="S1"),
                              statement("S4", "decision", "Garder le pilote.", replaces="S3")], [], [])
        self.assertEqual([item["status"] for item in ledger.items], ["active", "active", "active"])
        self.assertIn("ignoré", ledger.items[2]["notes"][0])

    def test_replacement_without_target_changes_nothing(self):
        self.ledger.add_window(1, [statement("S4", "withdrawn", "Retirer quelque chose.", "Bea", "S4")], ["L1"], [])
        self.assertEqual(self.ledger.items[0]["status"], "active")
        self.assertIn("sans élément relié", self.ledger.items[1]["notes"][0])


class InvariantTests(unittest.TestCase):
    def test_random_statements_never_list_an_ungrounded_owner(self):
        import random
        generator = random.Random(7)
        speakers = ["Ana", "Bea", "Cy", None]
        for _ in range(200):
            rows = [(generator.choice(speakers), f"Parole {index}.", generator.random() < 0.1) for index in range(12)]
            ledger = ledger_for(*rows)
            people = module.participants(list(ledger.turns.values()))
            for window in range(2):
                ids = [f"S{index}" for index in range(1 + window * 6, 7 + window * 6)]
                context_ids = [item["id"] for item in ledger.items if item["status"] == "active"]
                statements = [statement(generator.choice(ids), generator.choice(module.KINDS), f"Élément {window}-{number}.",
                                        generator.choice(people + [None]) if people else None,
                                        generator.choice(ids + [None]), generator.sample(ids, 2),
                                        generator.choice(context_ids + ids + [None, None]))
                              for number in range(5)]
                ledger.add_window(window, statements, context_ids, [])
            for item in ledger.items:
                if item["status"] == "active" and item["section"] == "task":
                    source = item["owner_turn"] or item["turn"]
                    self.assertEqual(ledger.speaker(source), item["owner"])
                    self.assertTrue(ledger.turns[source]["identified"] and not ledger.turns[source]["echo_suspect"])
                if item["kind"] not in module.COMMITMENT_KINDS + ("withdrawn",):
                    self.assertIsNone(item["owner"])
                if item["status"] != "active":
                    successor = next(entry for entry in ledger.items if entry["id"] == item["successor"])
                    self.assertIn(item["id"], successor.get("applied_to", []))


class Version3RuleTests(unittest.TestCase):
    def test_a_refusal_never_grounds_a_task_or_a_handover(self):
        ledger = ledger_for(("Ana", "Bea, tu peux organiser la dégustation ?"), ("Bea", "Ça, je ne te le promets pas."),
                            ("Cy", "Je m'occupe des inscriptions."), ("Ana", "Bea, tu reprends les inscriptions ?"),
                            ("Bea", "Pas cette semaine, je ne peux pas les prendre."))
        ledger.add_window(0, [statement("S1", "task", "Organiser la dégustation.", "Bea", "S2"),
                              statement("S3", "task", "Inscrire les nouveaux.", "Cy", "S3"),
                              statement("S4", "task", "Inscrire les nouveaux.", "Bea", "S5", replaces="S3")], [], [])
        tasting, registrations, handover = ledger.items
        self.assertEqual((tasting["section"], tasting["owner_status"]), ("to_confirm", "refusal_cue"))
        self.assertIn("refus ou une réserve", tasting["reason"])
        self.assertEqual((registrations["status"], registrations["section"]), ("active", "task"))
        self.assertEqual(handover["section"], "to_confirm")

    def test_withdrawals_are_not_replacement_targets_and_turn_references_prefer_the_same_owner(self):
        ledger = ledger_for(("Ana", "Je rédige le guide ; je ne prends pas la formation."), ("Bea", "D'accord."),
                            ("Ana", "Correction : un brouillon seulement."))
        ledger.add_window(0, [statement("S1", "task", "Rédiger le guide.", "Ana", "S1"),
                              statement("S1", "unassigned_followup", "Former les clients."),
                              statement("S3", "task", "Livrer un brouillon du guide.", "Ana", "S3", replaces="S1")], [], [])
        guide, training, draft = ledger.items
        self.assertEqual((guide["status"], training["status"], draft["status"]), ("superseded", "active", "active"))
        other = ledger_for(("Ana", "Je propose des badges."), ("Bea", "Non."), ("Ana", "Alors des stickers."))
        other.add_window(0, [statement("S1", "proposal", "Faire des badges."),
                             statement("S2", "withdrawn", "Refuser les badges.", replaces="S1"),
                             statement("S3", "proposal", "Faire des stickers.", replaces="S2")], [], [])
        self.assertEqual([item["status"] for item in other.items], ["withdrawn", "active", "active"])

    def test_a_replacement_without_any_shared_word_is_ignored(self):
        self.assertTrue(module.linked("Corriger le test de révocation.", "Déposer la correction du test."))
        self.assertTrue(module.linked("Fermer le restaurant le lundi.", "Fermer le mardi au lieu du lundi."))
        self.assertFalse(module.linked("Déclarer le local à l'assurance.", "Appeler le poissonnier demain."))
        ledger = ledger_for(("Ana", "Il faudra déclarer le local à l'assurance."), ("Lucie", "J'appelle le poissonnier demain."))
        ledger.add_window(0, [statement("S1", "unassigned_followup", "Déclarer le local à l'assurance.")], [], [])
        ledger.add_window(1, [statement("S2", "task", "Appeler le poissonnier demain.", "Lucie", "S2", replaces="L1")], ["L1"], [])
        self.assertEqual([item["status"] for item in ledger.items], ["active", "active"])
        self.assertIn("sans mot commun", ledger.items[1]["notes"][0])

    def test_restatements_merge_instead_of_replacing(self):
        ledger = ledger_for(("Ana", "Je réserve l'hôtel vendredi."), ("Bea", "On garde l'essai gratuit ?"), ("Cy", "D'accord, essai gratuit."),
                            ("Ana", "Je récapitule : je réserve l'hôtel, et on garde l'essai gratuit."))
        # Same window: identical restatements fold into the first item.
        ledger.add_window(0, [statement("S1", "task", "Réserver l'hôtel.", "Ana", "S1", due="vendredi"),
                              statement("S3", "decision", "Garder l'essai gratuit.", support=["S2"]),
                              statement("S4", "decision", "Garder l'essai gratuit."),
                              statement("S4", "task", "Réserver l'hôtel.", "Ana", "S4", replaces="S1")], [], [])
        self.assertEqual([item["status"] for item in ledger.items], ["active", "active"])
        self.assertIn("S4", ledger.items[0]["turns"])
        self.assertIn("S4", ledger.items[1]["turns"])
        # Later window: a restatement through replaces is a confirmation, not a replacement.
        ledger.add_window(1, [statement("S4", "task", "Réserver l'hôtel.", "Ana", "S4", replaces="L1")], ["L1", "L2"], [])
        self.assertEqual([item["status"] for item in ledger.items], ["active", "active", "merged"])
        result = module.summarize(ledger, list(ledger.turns.values()), {"overview": "R.", "key_points": [], "details": []})
        self.assertEqual((len(result["decisions"]), len(result["action_items"]), result["changes"]), (1, 1, []))
        self.assertEqual(result["action_items"][0]["due_text"], "vendredi")

    def test_a_dropped_request_is_not_rendered_as_a_withdrawn_commitment(self):
        ledger = ledger_for(("Ana", "Bea, tu peux refaire la grille ?"), ("Bea", "Là-dessus, je ne m'engage pas."), ("Bea", "Je fais le planning."))
        ledger.add_window(0, [statement("S1", "task", "Refaire la grille.", "Bea", None),
                              statement("S2", "withdrawn", "Refuser la grille.", "Bea", "S2", replaces="S1"),
                              statement("S3", "task", "Faire le planning.", "Bea", "S3")], [], [])
        text = module.markdown(module.summarize(ledger, list(ledger.turns.values()), {"overview": "R.", "key_points": [], "details": []}))
        self.assertIn("- Non retenu : « Refaire la grille », abandonné ou refusé par Bea", text)
        self.assertNotIn("Retiré", text)


class DeadlineAndContextTests(unittest.TestCase):
    def test_deadlines_must_be_spoken_and_iso_dates_must_be_literal(self):
        ledger = ledger_for(("Ana", "I will submit it by October 30, 2026."), ("Bea", "Je le fais d'ici jeudi prochain."), ("Cy", "Je l'envoie le 2026-11-03."))
        ledger.add_window(0, [statement("S1", "task", "Soumettre le correctif.", "Ana", "S1", due="avant le 30 octobre 2026"),
                              statement("S2", "task", "Préparer le devis.", "Bea", "S2", due="d'ici le 5 novembre"),
                              statement("S3", "task", "Envoyer le contrat.", "Cy", "S3", due="le 2026-11-03")], [], [])
        first, second, third = ledger.items
        self.assertEqual((first["due_status"], first["due_date"]), ("supported", None))
        self.assertEqual((second["due_status"], second["due_text"]), ("rejected_unsupported", None))
        self.assertEqual(third["due_date"], "2026-11-03")

    def test_prior_ledger_is_bounded_prioritized_and_reports_omissions(self):
        rows = [("Ana", f"Je m'occupe de la tâche numéro {index} avec une longue description pour remplir le budget.") for index in range(20)]
        ledger = ledger_for(*rows)
        ledger.add_window(0, [statement(f"S{index + 1}", "proposal" if index % 2 else "task", f"Tâche {index} " + "x" * 120, "Ana", f"S{index + 1}")
                              for index in range(20)], [], [])
        context, omitted = ledger.context()
        self.assertLessEqual(len(module.compact(context)), module.LEDGER_CONTEXT_CHARACTERS)
        self.assertLessEqual(len(context), module.LEDGER_CONTEXT_ITEMS)
        self.assertEqual(len(context) + len(omitted), 20)
        self.assertTrue(all(entry["kind"] == "task" for entry in context))
        self.assertEqual([entry["id"] for entry in context], sorted((entry["id"] for entry in context), key=lambda name: int(name[1:])))

    def test_language_check_flags_english_items(self):
        self.assertTrue(module.looks_english("Fix the revocation test by October 30."))
        self.assertFalse(module.looks_english("Corriger le test de révocation avant le 30 octobre."))

    def test_prepare_reserves_the_full_ledger_budget(self):
        report = module.prepare([ATLAS_FR], 24_000, None)[0]
        self.assertEqual(report["windows"], 1)
        self.assertLessEqual(report["worst_case_extraction_prompt"], 24_000)
        self.assertLessEqual(report["worst_case_writer_prompt"], 24_000)


class FakeClient:
    def __init__(self, responses):
        self.responses, self.requests = list(responses), []

    def complete(self, system, prompt, schema, max_tokens, name):
        self.requests.append(prompt)
        content, finish = self.responses.pop(0)
        return {"content": content, "finish_reason": finish, "usage": {"prompt_tokens": 10}, "reasoning_characters": 0,
                "seconds": 0.01, "request_bytes": len(prompt)}


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.parse = lambda content: module.load_content(content)["value"] if "value" in module.load_content(content) else (_ for _ in ()).throw(module.InvalidResponse("missing value"))

    def tearDown(self):
        shutil.rmtree(self.directory)

    def runner(self, client):
        return module.Runner(client, self.directory, "identity", self.directory / "calls.jsonl")

    def test_retry_once_then_checkpoint_and_reuse(self):
        client = FakeClient([('{"other": 1}', "stop"), ('{"value": 2}', "stop")])
        self.assertEqual(self.runner(client).call("ledger", "1/1", "system", "LEDGER: x", {"type": "object"}, 10, self.parse, 1_000), 2)
        self.assertTrue(client.requests[1].startswith(module.RETRY_PREFIX))
        self.assertTrue(client.requests[1].endswith("\nLEDGER: x"))
        reused = FakeClient([])
        runner = self.runner(reused)
        self.assertEqual(runner.call("ledger", "1/1", "system", "LEDGER: x", {"type": "object"}, 10, self.parse, 1_000), 2)
        self.assertEqual((reused.requests, runner.records[0]["cached"]), ([], True))

    def test_second_invalid_answer_and_truncated_output_fail(self):
        with self.assertRaises(module.InvalidResponse):
            self.runner(FakeClient([('{"value": 1}', "length"), ("nope", "stop")])).call("write", "1/1", "s", "WRITE: x", {}, 10, self.parse, 100)
        self.assertEqual(list(self.directory.glob("*.json")), [])

    def test_invalid_checkpoint_is_removed_and_regenerated(self):
        client = FakeClient([('{"value": 3}', "stop")])
        runner = self.runner(client)
        key = module.digest(module.compact({"identity": "identity", "stage": "ledger", "system": "s", "prompt": "LEDGER: y",
                                            "schema": {}, "max_tokens": 10}))
        (self.directory / f"{key}.json").write_text('{"content": "{\\"other\\": 1}"}')
        self.assertEqual(runner.call("ledger", "1/1", "s", "LEDGER: y", {}, 10, self.parse, 100), 3)
        self.assertIn("removed_invalid_checkpoint", runner.records[0])

    def test_cache_key_changes_with_the_prompt_and_oversized_prompts_never_reach_the_model(self):
        client = FakeClient([('{"value": 1}', "stop"), ('{"value": 2}', "stop")])
        runner = self.runner(client)
        runner.call("ledger", "1/1", "s", "LEDGER: a", {}, 10, self.parse, 100)
        self.assertEqual(runner.call("ledger", "1/1", "s", "LEDGER: b", {}, 10, self.parse, 100), 2)
        with self.assertRaises(module.BudgetError):
            runner.call("ledger", "1/1", "s", "x" * 101, {}, 10, self.parse, 100)
        self.assertEqual(len(client.requests), 2)

    def test_call_budget_stops_before_an_extra_request(self):
        client = FakeClient([('{"other": 1}', "stop"), ('{"value": 2}', "stop")])
        runner = module.Runner(client, self.directory, "identity", self.directory / "calls.jsonl", max_calls=1)
        with self.assertRaises(module.CallBudgetExceeded):
            runner.call("ledger", "1/1", "s", "LEDGER: x", {}, 10, self.parse, 1_000)
        self.assertEqual(len(client.requests), 1)

    def test_client_accepts_only_loopback_endpoints(self):
        for endpoint in ("http://example.com/v1", "http://user:pass@127.0.0.1/v1", "http://127.0.0.1:1234/v1?x=1"):
            with self.assertRaises(ValueError):
                module.Client(endpoint, "model")
        client = module.Client("http://127.0.0.1:1234/v1", "model", "none")
        self.assertEqual(client.body("s", "p", {}, 5, "n")["reasoning_effort"], "none")
        self.assertNotIn("reasoning_effort", module.Client("http://localhost:1234/v1", "model").body("s", "p", {}, 5, "n"))


ATLAS_STATEMENTS = [
    statement("S1", "proposal", "Lancer vendredi pour tous les clients."),
    statement("S3", "withdrawn", "Retirer la proposition de lancement vendredi.", "Camille", "S3", ["S2"], replaces="S1"),
    statement("S4", "decision", "Limiter le lancement à un pilote interne de vingt personnes.", support=["S3"]),
    statement("S6", "task", "Corriger le test de révocation.", "Jordan", "S6", ["S5"], due="avant le 30 octobre 2026"),
    statement("S7", "task", "Rédiger le guide du pilote.", "Camille", "S7", due="avant le 29 octobre 2026"),
    statement("S10", "unassigned_followup", "Relancer la finance sur le budget."),
    statement("S13", "open_question", "Fixer la durée de conservation des journaux.", support=["S11", "S12"]),
    statement("S15", "task", "Livrer un brouillon du guide du pilote.", "Camille", "S15", replaces="S7", due="le 29 octobre"),
    statement("S17", "decision", "Utiliser l'anglais et le français pour le pilote."),
    statement("S18", "decision", "Reporter l'annonce publique jusqu'à la validation des tests."),
]
WRITING = {"details": [{"title": "Pilote interne", "text": "Le lancement général est écarté au profit d'un pilote interne.", "evidence_turns": ["S3", "S4"]}],
           "key_points": [], "overview": "Le portail démarre par un pilote interne ; le budget reste ouvert."}


class StubServer(http.server.ThreadingHTTPServer):
    def __init__(self):
        self.requests = []
        super().__init__(("127.0.0.1", 0), StubHandler)


class StubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.reply({"models": []})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append(body)
        prompt = body["messages"][1]["content"]
        stage = next(line.split(":")[0] for line in prompt.splitlines() if line.split(":")[0] in ("LEDGER", "WRITE", "WRITE_CHAPTER", "EXECUTIVE"))
        payload = json.loads(prompt.splitlines()[-1])
        if stage == "LEDGER":
            # Answer only with turns of this window, as the constrained schema would.
            ids = {row["id"] for row in payload["transcript"]} | {entry["id"] for entry in payload["prior_ledger"]}
            content = {"statements": [dict(row, owner_turn=row["owner_turn"] if row["owner_turn"] in ids else None,
                                           support_turns=[sid for sid in row["support_turns"] if sid in ids],
                                           replaces=row["replaces"] if row["replaces"] in ids else None)
                                      for row in ATLAS_STATEMENTS if row["turn"] in ids]}
        elif stage == "EXECUTIVE":
            content = {"key_points": [], "overview": "Synthèse des parties."}
        else:
            first = payload["transcript"][0]["id"]
            content = dict(WRITING, details=[dict(WRITING["details"][0], evidence_turns=[first])],
                           key_points=[] if stage == "WRITE_CHAPTER" else WRITING["key_points"])
        self.reply({"choices": [{"message": {"content": json.dumps(content, ensure_ascii=False)}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 1234, "completion_tokens": 56}})

    def reply(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.server = StubServer()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.directory = Path(tempfile.mkdtemp())
        self.args = SimpleNamespace(endpoint=f"http://127.0.0.1:{self.server.server_address[1]}/v1", model="stub", reasoning_effort="none",
                                    input_characters=24_000, window_characters=None, cache_seed=None, server_pid=[], sample_interval=0.1,
                                    timeout=60, quantization="test", context_tokens=None, allow_holdout=False)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.directory)

    def test_short_path_uses_two_calls_and_commitments_come_only_from_the_ledger(self):
        harness = module.load_harness()
        self.assertTrue(module.run_case(ATLAS_FR, self.directory / "fresh", self.args, harness))
        output = self.directory / "fresh"
        report = json.loads((output / "benchmark.json").read_text())
        result = json.loads((output / "result.json").read_text())
        metrics = json.loads((output / "metrics.json").read_text())
        self.assertEqual((report["status"], report["run_type"], report["source_unchanged"]), ("completed", "fresh", True))
        self.assertEqual(report["prompt_hash"], module.PROMPT_HASH)
        self.assertEqual((metrics["model_calls"], metrics["calls_by_stage"]["ledger"], metrics["calls_by_stage"]["write"]), (2, 1, 1))
        self.assertEqual(metrics["max_prompt_tokens"], 1234)
        self.assertGreater(metrics["memory"]["samples"], 0)
        self.assertEqual([item["assignee_name"] for item in result["action_items"]], ["Jordan", "Camille"])
        self.assertEqual(result["action_items"][1]["text"], "Livrer un brouillon du guide du pilote.")
        self.assertEqual(len(result["decisions"]), 3)
        self.assertEqual({change["status"] for change in result["changes"]}, {"withdrawn", "superseded"})
        self.assertEqual([item["kind"] for item in result["follow_ups"]], ["unassigned_followup"])
        self.assertEqual(result["details"][0]["evidence_segment_ids"], ["4AE825C4-D843-5A73-AA37-853A68889D0C"])
        writer_request = next(body for body in self.server.requests if body["messages"][1]["content"].startswith("WRITE:"))
        self.assertNotIn("action_items", writer_request["response_format"]["json_schema"]["schema"]["properties"])
        self.assertIn('"ledger":[', writer_request["messages"][1]["content"])
        summary = (output / "summary.md").read_text()
        self.assertIn("- Jordan : Corriger le test de révocation. (avant le 30 octobre 2026)", summary)
        with patch("builtins.print"):
            module.score(self.directory)
        counts = json.loads((output / "score.json").read_text())["counts"]
        self.assertEqual((counts["decision_recall"], counts["task_recall"], counts["forbidden_hits"]), ("3/3", "2/2", 0))
        self.assertIn("S6 Jordan: Je m’en charge.", (output / "review.md").read_text())
        self.assertNotIn("\u2014", summary)
        # A resumed run copies validated checkpoints and makes no new request.
        count = len(self.server.requests)
        self.args.cache_seed = output / "cache"
        self.assertTrue(module.run_case(ATLAS_FR, self.directory / "resumed", self.args, harness))
        resumed = json.loads((self.directory / "resumed/benchmark.json").read_text())
        self.assertEqual((len(self.server.requests), resumed["run_type"], resumed["metrics"]["cached_calls"]), (count, "resumed", 2))
        self.assertFalse(resumed["timing_comparable_with_fresh"])

    def test_environment_proxies_are_ignored(self):
        client = module.Client(self.args.endpoint, "stub")
        unreachable = {"http_proxy": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9", "no_proxy": "", "NO_PROXY": ""}
        with patch.dict(module.os.environ, unreachable):
            client = module.Client(self.args.endpoint, "stub")
            response = client.complete("s", "WRITE: x\n" + json.dumps({"transcript": [{"id": "S1"}]}), {}, 10, "n")
        self.assertEqual(response["finish_reason"], "stop")

    def test_several_windows_carry_a_bounded_ledger_and_add_an_executive_call(self):
        harness = module.load_harness()
        self.args.window_characters = 1_000
        self.assertTrue(module.run_case(ATLAS_FR, self.directory / "windows", self.args, harness))
        metrics = json.loads((self.directory / "windows/metrics.json").read_text())
        self.assertGreater(metrics["windows"], 1)
        self.assertEqual(metrics["calls_by_stage"], {"ledger": metrics["windows"], "write": metrics["windows"], "executive": 1})
        ledger_prompts = [body["messages"][1]["content"] for body in self.server.requests if body["messages"][1]["content"].startswith("LEDGER:")]
        self.assertIn('"prior_ledger":[]', ledger_prompts[0])
        self.assertNotIn('"prior_ledger":[]', ledger_prompts[1])
        self.assertTrue(all(len(prompt) <= 24_000 for prompt in ledger_prompts))


class FakeRunner:
    """Stage-aware stand-in for Runner: returns schema-valid content and records prompts."""

    def __init__(self):
        self.prompts = []

    def call(self, stage, label, system, prompt, schema, max_tokens, parse, limit):
        self.prompts.append((stage, prompt))
        if len(prompt) > limit:
            raise module.BudgetError("too large")
        if stage == "ledger":
            return parse(json.dumps({"statements": []}))
        if stage == "write":
            first = json.loads(prompt.splitlines()[-1])["transcript"][0]["id"]
            topic = {"title": f"Partie {label}", "text": "Contenu détaillé. " * 110, "evidence_turns": [first]}
            return parse(json.dumps({"details": [topic], "key_points": [], "overview": "Une partie."}))
        payload = json.loads(prompt.splitlines()[-1])
        sid = payload["chapters"][0]["evidence_turns"][0]
        return parse(json.dumps({"key_points": [{"title": "Point", "text": "Un point.", "evidence_turns": [sid]}],
                                 "overview": f"Synthèse après {len(payload['chapters'])} chapitres."}))


class LongSessionTests(unittest.TestCase):
    def test_executive_batches_stay_bounded_and_carry_previous_points(self):
        rows = [("Ana" if index % 2 else "Bea", f"Tour {index} : " + "discussion du projet et de ses étapes. " * 6) for index in range(240)]
        data = recording(*rows)
        turns = module.build_turns(data)
        runner = FakeRunner()
        result, ledger, notes = module.generate(data, turns, runner, 24_000, 2_000)
        executive = [prompt for stage, prompt in runner.prompts if stage == "executive"]
        self.assertGreater(len(executive), 1)
        self.assertTrue(all(len(prompt) <= 24_000 for _, prompt in runner.prompts))
        self.assertIn("Synthèse après", json.loads(executive[1].splitlines()[-1])["previous"]["overview"])
        self.assertEqual(len(result["details"]), notes["windows"])
        self.assertEqual(sum(1 for stage, _ in runner.prompts if stage == "ledger"), notes["windows"])


class ScoreTests(unittest.TestCase):
    def test_flags_promotions_owner_errors_forbidden_and_unmatched(self):
        items = [
            {"id": "L1", "status": "active", "section": "task", "owner": "Bea", "turn_uuids": ["A"], "text": "x", "due_text": None},
            {"id": "L2", "status": "active", "section": "task", "owner": "Ana", "turn_uuids": ["B"], "text": "y", "due_text": None},
            {"id": "L3", "status": "active", "section": "decision", "owner": None, "turn_uuids": ["Z"], "text": "z", "due_text": None},
            {"id": "L4", "status": "active", "section": "task", "owner": "Cy", "turn_uuids": ["C"], "text": "w", "due_text": "jeudi"}]
        expected = {"items": [
            {"id": "E1", "match_segment_ids": ["A"], "expected_section": "task", "acceptable_sections": ["task"], "owner": "Ana", "final_status": "active", "due_text_contains": []},
            {"id": "E2", "match_segment_ids": ["B"], "expected_section": "to_confirm", "acceptable_sections": ["to_confirm"], "owner": None, "final_status": "active", "due_text_contains": []},
            {"id": "E3", "match_segment_ids": ["C"], "expected_section": "task", "acceptable_sections": ["task"], "owner": "Cy", "final_status": "withdrawn", "due_text_contains": []}],
            "forbidden": [{"id": "F1", "section": "task", "owner": "Ana", "match_segment_ids": ["B"]}]}
        counts = module.score_case(items, expected)["counts"]
        self.assertEqual((counts["owner_errors"], counts["promotions"], counts["forbidden_hits"], counts["stale"], counts["unmatched_commitments"]), (1, 1, 1, 1, 1))
        self.assertEqual(counts["task_recall"], "0/1")

    def test_relative_deadlines_compare_across_languages(self):
        entry = {"id": "E1", "match_segment_ids": ["A"], "expected_section": "task", "acceptable_sections": ["task"], "owner": "Ana",
                 "final_status": "active", "due_text_contains": ["demain"]}
        item = {"id": "L1", "status": "active", "section": "task", "owner": "Ana", "turn_uuids": ["A"], "text": "x", "due_text": "tomorrow morning"}
        self.assertEqual(module.score_case([item], {"items": [entry], "forbidden": []})["counts"]["deadline_flags"], 0)
        item["due_text"] = "next week"
        self.assertEqual(module.score_case([item], {"items": [entry], "forbidden": []})["counts"]["deadline_flags"], 1)

    def test_shared_recap_turns_do_not_create_owner_errors(self):
        items = [{"id": "L1", "status": "active", "section": "task", "owner": "Mehdi", "turn_uuids": ["M", "R"], "text": "x", "due_text": None}]
        expected = {"items": [
            {"id": "E1", "match_segment_ids": ["H", "R"], "expected_section": "task", "acceptable_sections": ["task"], "owner": "Hélène", "final_status": "active", "due_text_contains": []},
            {"id": "E2", "match_segment_ids": ["M", "R"], "expected_section": "task", "acceptable_sections": ["task"], "owner": "Mehdi", "final_status": "active", "due_text_contains": []}],
            "forbidden": []}
        counts = module.score_case(items, expected)["counts"]
        self.assertEqual((counts["owner_errors"], counts["task_recall"]), (0, "1/2"))

    def test_atlas_expectations_convert_to_decision_and_task_items(self):
        expected = module.load_expected(module.ATLAS / "fr.expected.json")
        self.assertEqual([item["expected_section"] for item in expected["items"]], ["decision"] * 3 + ["task"] * 2)
        self.assertEqual(expected["items"][3]["due_text_contains"], ["30", "octobre"])
        item = {"id": "L1", "status": "active", "section": "task", "owner": "Jordan", "turn_uuids": expected["items"][3]["match_segment_ids"][:1],
                "text": "Corriger le test.", "due_text": "by October 30, 2026"}
        counts = module.score_case([item], {"items": [expected["items"][3]], "forbidden": []})["counts"]
        self.assertEqual((counts["task_recall"], counts["deadline_flags"]), ("1/1", 0))


if __name__ == "__main__":
    unittest.main()
