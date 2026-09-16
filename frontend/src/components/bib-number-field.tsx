import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { Input } from "@/components/ui/input";

interface BibNumberFieldProps {
  value: string | null;
  /** Rejecting here (throwing) leaves the field in edit mode with the typed
   *  text intact, which is what a duplicate-bib 422 needs — the organizer has
   *  to pick a different number, and retyping the whole thing is punishment
   *  for the server's answer. */
  onSave: (next: string | null) => Promise<unknown>;
  disabled?: boolean;
}

/**
 * Inline editor for a participant's race number.
 *
 * Click-to-edit rather than a permanently-open input: the overwhelmingly
 * common state is "already assigned, don't touch", and a grid of open text
 * boxes reads as a form that needs filling in. A dash marks unassigned, which
 * is also the click target — an empty cell would be invisible.
 *
 * Saves on blur and on Enter; Escape reverts. There's no save button because
 * the field holds one short value with no validation the client can do.
 */
export function BibNumberField({ value, onSave, disabled = false }: BibNumberFieldProps) {
  const { t } = useTranslation();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value ?? "");
  const [saving, setSaving] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  // Re-sync when the row's data changes underneath us — a refetch after
  // check-in, or another organizer's edit arriving. Skipped while editing so
  // a background refetch can't overwrite what someone is mid-way through
  // typing.
  useEffect(() => {
    if (!editing) setDraft(value ?? "");
  }, [value, editing]);

  useEffect(() => {
    if (editing) inputRef.current?.select();
  }, [editing]);

  const commit = async () => {
    const next = draft.trim() || null;
    if (next === (value ?? null)) {
      setEditing(false);
      return;
    }

    setSaving(true);
    try {
      await onSave(next);
      setEditing(false);
    } catch {
      // Stay open with the typed value — see onSave's note. The caller
      // surfaces the reason as a toast.
      inputRef.current?.focus();
    } finally {
      setSaving(false);
    }
  };

  if (!editing) {
    return (
      <button
        type="button"
        disabled={disabled}
        onClick={() => setEditing(true)}
        aria-label={t("manageEvent.bibEditLabel")}
        className="min-w-14 rounded-md border border-dashed border-border px-2 py-0.5 text-left font-mono text-xs text-muted-foreground transition-colors hover:border-solid hover:text-foreground disabled:cursor-not-allowed disabled:opacity-50"
      >
        {value ?? "—"}
      </button>
    );
  }

  return (
    <Input
      ref={inputRef}
      value={draft}
      disabled={saving}
      maxLength={32}
      inputMode="numeric"
      aria-label={t("manageEvent.bibEditLabel")}
      placeholder={t("manageEvent.bibPlaceholder")}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={commit}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          void commit();
        } else if (e.key === "Escape") {
          e.preventDefault();
          setDraft(value ?? "");
          setEditing(false);
        }
      }}
      className="h-7 w-20 font-mono text-xs"
    />
  );
}
