import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

// Initialises the i18next singleton. Without it `t()` returns raw keys and
// these assertions would match "certificateTemplate.preview" rather than
// "Preview" — passing for the wrong reason and never catching a missing
// translation.
import "@/lib/i18n";
import { CertificateTemplateUpload } from "@/components/certificate-template-upload";
import { uploadsApi, certificatePreviewApi } from "@/lib/api-client";

/**
 * Covers the two things with real consequences for an organizer:
 *
 *  - The split-token warning actually appears. That warning is the only thing
 *    standing between a broken template and every participant receiving a
 *    certificate reading "{{participant_name}}".
 *  - The preview polls until the render finishes, and reports a failure rather
 *    than spinning forever.
 */

const ODT = new File(["zip bytes"], "template.odt", {
  type: "application/vnd.oasis.opendocument.text",
});

function uploadResult(over: Partial<ReturnType<typeof baseCheck>> = {}) {
  return {
    url: "https://example.com/template.odt",
    signed_id: "signed-abc",
    template_check: { ...baseCheck(), ...over },
  };
}

function baseCheck() {
  return {
    valid_odt: true,
    usable: true,
    present: ["participant_name", "event_title", "event_date", "event_location"],
    split: [] as string[],
    missing: [] as string[],
  };
}

function renderComponent(value: string | null = null) {
  const onChange = vi.fn();
  const utils = render(
    <CertificateTemplateUpload value={value} onChange={onChange} eventId="event-1" />,
  );
  return { ...utils, onChange };
}

async function upload() {
  const input = document.querySelector('input[type="file"]') as HTMLInputElement;
  await userEvent.upload(input, ODT);
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("CertificateTemplateUpload", () => {
  it("confirms how many placeholders were found on a healthy template", async () => {
    vi.spyOn(uploadsApi, "uploadCertificateTemplate").mockResolvedValue(uploadResult());

    renderComponent();
    await upload();

    expect(await screen.findByText(/4 of 4 placeholders/i)).toBeInTheDocument();
  });

  it("warns about a token split across formatting and names it", async () => {
    vi.spyOn(uploadsApi, "uploadCertificateTemplate").mockResolvedValue(
      uploadResult({ split: ["participant_name"], usable: false, present: ["event_title"] }),
    );

    renderComponent();
    await upload();

    expect(await screen.findByText(/broken placeholder/i)).toBeInTheDocument();
    // Scoped to the warning sentence: the bare token also appears in the
    // always-visible reference list at the bottom, so matching it alone finds
    // two elements.
    expect(
      screen.getByText(/\{\{participant_name\}\} is split across formatting/i),
    ).toBeInTheDocument();
  });

  it("reports missing tokens as informational, not as a problem", async () => {
    vi.spyOn(uploadsApi, "uploadCertificateTemplate").mockResolvedValue(
      uploadResult({ missing: ["event_location"], present: ["participant_name"] }),
    );

    renderComponent();
    await upload();

    expect(await screen.findByText(/not used in this template/i)).toBeInTheDocument();
    expect(screen.queryByText(/broken placeholder/i)).not.toBeInTheDocument();
  });

  it("polls until the render is ready and then shows the pdf", async () => {
    vi.spyOn(uploadsApi, "uploadCertificateTemplate").mockResolvedValue(uploadResult());
    vi.spyOn(certificatePreviewApi, "request").mockResolvedValue({
      preview: { status: "pending", file_url: null, error_code: null, updated_at: "" },
    });
    const get = vi
      .spyOn(certificatePreviewApi, "get")
      .mockResolvedValueOnce({
        preview: { status: "pending", file_url: null, error_code: null, updated_at: "" },
      })
      .mockResolvedValue({
        preview: {
          status: "ready",
          file_url: "https://example.com/preview.pdf",
          error_code: null,
          updated_at: "",
        },
      });

    renderComponent("https://example.com/template.odt");
    await upload();

    await userEvent.click(await screen.findByRole("button", { name: /preview/i }));

    await waitFor(
      () => expect(screen.getByRole("link", { name: /open preview/i })).toBeInTheDocument(),
      { timeout: 10_000 },
    );
    // Polled rather than assumed ready from the POST response.
    expect(get.mock.calls.length).toBeGreaterThan(1);
  }, 15_000);

  it("surfaces a render failure instead of spinning forever", async () => {
    vi.spyOn(uploadsApi, "uploadCertificateTemplate").mockResolvedValue(uploadResult());
    vi.spyOn(certificatePreviewApi, "request").mockResolvedValue({
      preview: { status: "pending", file_url: null, error_code: null, updated_at: "" },
    });
    vi.spyOn(certificatePreviewApi, "get").mockResolvedValue({
      preview: {
        status: "failed",
        file_url: null,
        error_code: "conversion_failed",
        updated_at: "",
      },
    });

    renderComponent("https://example.com/template.odt");
    await upload();
    await userEvent.click(await screen.findByRole("button", { name: /preview/i }));

    expect(await screen.findByText(/LibreOffice couldn't open/i, {}, { timeout: 10_000 }))
      .toBeInTheDocument();
  }, 15_000);

  it("offers no preview until a template has been uploaded in this session", () => {
    // `value` alone isn't enough: previewing needs the signed_id, which only
    // exists after an upload. A saved template from a previous visit has a URL
    // but no signed id, and offering a button that can't work would be worse
    // than not offering one.
    renderComponent("https://example.com/saved-template.odt");

    expect(screen.queryByRole("button", { name: /preview/i })).not.toBeInTheDocument();
  });
});
