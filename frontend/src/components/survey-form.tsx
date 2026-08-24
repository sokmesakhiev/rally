/**
 * SurveyForm — shown to participants during event registration.
 * Renders questions and collects answers; calls onSubmit with the answers array.
 */
import { useState } from "react";
import { Loader2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import type { ApiSurvey, ApiRegistrationAnswer } from "@/lib/api-client";

interface SurveyFormProps {
  survey: ApiSurvey;
  brandColor: string;
  onSubmit: (answers: ApiRegistrationAnswer[]) => void;
  onBack: () => void;
  isPending: boolean;
  /** Overrides the submit button's label — e.g. "Review & confirm" when a
   * confirm step follows instead of registering immediately. Defaults to
   * surveyForm.completeRegistration. */
  submitLabel?: string;
}

export function SurveyForm({
  survey,
  brandColor,
  onSubmit,
  onBack,
  isPending,
  submitLabel,
}: SurveyFormProps) {
  const { t } = useTranslation();
  // answers keyed by question id
  const [textAnswers, setTextAnswers] = useState<Record<string, string>>({});
  const [choiceAnswers, setChoiceAnswers] = useState<Record<string, string[]>>({});

  function toggleOption(questionId: string, optionId: string, single: boolean) {
    setChoiceAnswers((prev) => {
      const current = prev[questionId] ?? [];
      if (single) {
        // radio behaviour
        return { ...prev, [questionId]: [optionId] };
      }
      // checkbox behaviour
      return {
        ...prev,
        [questionId]: current.includes(optionId)
          ? current.filter((id) => id !== optionId)
          : [...current, optionId],
      };
    });
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();

    // Validate required questions
    for (const q of survey.questions) {
      if (!q.required) continue;
      if (q.question_type === "text" && !textAnswers[q.id]?.trim()) {
        alert(t("surveyForm.requiredAlert", { question: q.question_text }));
        return;
      }
      if (
        (q.question_type === "single_choice" || q.question_type === "multiple_choice") &&
        !choiceAnswers[q.id]?.length
      ) {
        alert(t("surveyForm.requiredAlert", { question: q.question_text }));
        return;
      }
    }

    const answers: ApiRegistrationAnswer[] = survey.questions.map((q) => ({
      survey_question_id: q.id,
      answer_text: q.question_type === "text" ? (textAnswers[q.id] ?? "") : undefined,
      answer_options: q.question_type !== "text" ? (choiceAnswers[q.id] ?? []) : undefined,
    }));

    onSubmit(answers);
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-6">
      <div>
        <h3 className="font-semibold text-lg">{survey.title}</h3>
        <p className="text-sm text-muted-foreground mt-0.5">{t("surveyForm.subtitle")}</p>
      </div>

      {survey.questions.map((q, i) => (
        <div key={q.id} className="space-y-2">
          <Label className="text-sm font-medium">
            {i + 1}. {q.question_text}
            {q.required && <span className="text-destructive ml-1">*</span>}
          </Label>

          {q.question_type === "text" && (
            <Textarea
              value={textAnswers[q.id] ?? ""}
              onChange={(e) => setTextAnswers((prev) => ({ ...prev, [q.id]: e.target.value }))}
              placeholder={t("surveyForm.answerPlaceholder")}
              rows={3}
              className="resize-none"
            />
          )}

          {(q.question_type === "single_choice" || q.question_type === "multiple_choice") && (
            <div className="space-y-2 pl-1">
              {q.options.map((opt) => {
                const selected = (choiceAnswers[q.id] ?? []).includes(opt.id);
                const isSingle = q.question_type === "single_choice";
                return (
                  <div key={opt.id} className="flex items-center gap-2.5">
                    {isSingle ? (
                      /* Radio-style button */
                      <button
                        type="button"
                        onClick={() => toggleOption(q.id, opt.id, true)}
                        className={`h-4 w-4 rounded-full border-2 flex-shrink-0 transition-colors ${
                          selected ? "border-[var(--brand)]" : "border-muted-foreground/40"
                        }`}
                        style={
                          selected ? { borderColor: brandColor, backgroundColor: brandColor } : {}
                        }
                      />
                    ) : (
                      <Checkbox
                        id={`${q.id}-${opt.id}`}
                        checked={selected}
                        onCheckedChange={() => toggleOption(q.id, opt.id, false)}
                      />
                    )}
                    <label
                      htmlFor={isSingle ? undefined : `${q.id}-${opt.id}`}
                      className="text-sm cursor-pointer"
                      onClick={isSingle ? () => toggleOption(q.id, opt.id, true) : undefined}
                    >
                      {opt.label}
                    </label>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      ))}

      <div className="flex gap-3 pt-2">
        <Button type="button" variant="outline" onClick={onBack} disabled={isPending}>
          {t("common.back")}
        </Button>
        <Button
          type="submit"
          disabled={isPending}
          style={{ backgroundColor: brandColor }}
          className="flex-1 text-white hover:opacity-90 disabled:opacity-50"
        >
          {isPending && <Loader2 className="h-4 w-4 animate-spin" />}
          {submitLabel ?? t("surveyForm.completeRegistration")}
        </Button>
      </div>
    </form>
  );
}
