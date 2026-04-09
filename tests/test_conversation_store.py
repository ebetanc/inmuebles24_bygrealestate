"""Tests for the conversation store."""
from pathlib import Path

from inmobiliaria24.whatsapp.conversation_store import (
    Conversation, ConversationStore, Step,
)


def test_save_and_get(tmp_path: Path):
    store = ConversationStore(tmp_path / "conv.db")
    conv = Conversation(phone="5551234567", lead_id="100", name="Ana")
    store.save(conv)

    loaded = store.get("5551234567")
    assert loaded is not None
    assert loaded.name == "Ana"
    assert loaded.step == Step.NEW
    store.close()


def test_get_nonexistent(tmp_path: Path):
    store = ConversationStore(tmp_path / "conv.db")
    assert store.get("9999999") is None
    store.close()


def test_update_step(tmp_path: Path):
    store = ConversationStore(tmp_path / "conv.db")
    conv = Conversation(phone="555", lead_id="1")
    store.save(conv)

    conv.step = Step.AWAITING_BUDGET
    conv.intent = "comprar"
    store.save(conv)

    loaded = store.get("555")
    assert loaded.step == Step.AWAITING_BUDGET
    assert loaded.intent == "comprar"
    store.close()


def test_get_by_step(tmp_path: Path):
    store = ConversationStore(tmp_path / "conv.db")
    c1 = Conversation(phone="1", step=Step.AWAITING_INTENT)
    c2 = Conversation(phone="2", step=Step.QUALIFIED)
    c3 = Conversation(phone="3", step=Step.AWAITING_INTENT)
    store.save(c1)
    store.save(c2)
    store.save(c3)

    results = store.get_by_step(Step.AWAITING_INTENT)
    assert len(results) == 2
    store.close()


def test_context_manager(tmp_path: Path):
    with ConversationStore(tmp_path / "conv.db") as store:
        store.save(Conversation(phone="X"))
        assert store.get("X") is not None
