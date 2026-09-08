import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import {
  Loader2,
  Building2,
  Wallet,
  ShieldCheck,
  ExternalLink,
  Users,
  Plus,
  Trash2,
  CheckCircle2,
  CircleDashed,
} from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import {
  organizationsApi,
  type ApiOrganization,
  type ApiOrganizationMember,
  type OrganizationRole,
} from "@/lib/api-client";
import { SiteHeader } from "@/components/site-header";
import { ImageUpload } from "@/components/image-upload";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Textarea } from "@/components/ui/textarea";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
  CardFooter,
} from "@/components/ui/card";

export const Route = createFileRoute("/_authenticated/organizations")({
  head: () => ({ meta: [{ title: "Organization settings — Rally" }] }),
  component: OrganizationsPage,
});

/** Remembered client-side so an organizer who runs several lands back on the
 * one they were last working in. Not authoritative — the server is asked for
 * the list, and a stale slug simply falls back to the first. */
const LAST_ORG_KEY = "rally_last_organization";

function OrganizationsPage() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const [activeSlug, setActiveSlug] = useState<string | null>(null);

  const listQuery = useQuery({
    queryKey: ["organizations"],
    queryFn: () => organizationsApi.list().then((r) => r.organizations),
  });

  const organizations = listQuery.data ?? [];

  // Pick an organization once the list arrives: the remembered one if it's
  // still there, otherwise the first.
  useEffect(() => {
    if (activeSlug || organizations.length === 0) return;
    const remembered = localStorage.getItem(LAST_ORG_KEY);
    const match = organizations.find((o) => o.slug === remembered);
    setActiveSlug(match?.slug ?? organizations[0].slug);
  }, [organizations, activeSlug]);

  useEffect(() => {
    if (activeSlug) localStorage.setItem(LAST_ORG_KEY, activeSlug);
  }, [activeSlug]);

  const active = organizations.find((o) => o.slug === activeSlug) ?? null;

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ["organizations"] });
    if (activeSlug)
      queryClient.invalidateQueries({ queryKey: ["organization-members", activeSlug] });
  };

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />

      <main className="mx-auto max-w-3xl px-5 py-10">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="font-display text-3xl font-bold">{t("organization.title")}</h1>
            <p className="mt-2 text-sm text-muted-foreground">{t("organization.subtitle")}</p>
          </div>

          {/* Only a switcher when there's something to switch between — with
              one organization a dropdown is a decision that doesn't exist. */}
          {organizations.length > 1 && activeSlug && (
            <Select value={activeSlug} onValueChange={setActiveSlug}>
              <SelectTrigger className="w-56">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {organizations.map((o) => (
                  <SelectItem key={o.slug} value={o.slug}>
                    {o.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </div>

        {listQuery.isLoading && <p className="mt-8 text-muted-foreground">{t("common.loading")}</p>}

        {!listQuery.isLoading && organizations.length === 0 && (
          <CreateFirstOrganization onCreated={invalidate} />
        )}

        {active && (
          <div className="mt-8 space-y-6">
            <PublishReadiness organization={active} />
            <IdentityCard organization={active} onSaved={invalidate} />
            <ContactCard organization={active} onSaved={invalidate} />
            <MembersCard organization={active} />
            {active.role === "owner" && <PaymentCard organization={active} onSaved={invalidate} />}
          </div>
        )}
      </main>
    </div>
  );
}

/** A participant who has never organized anything has no organization yet.
 * Ticket E's publish gate needs one to exist before an event can go live. */
function CreateFirstOrganization({ onCreated }: { onCreated: () => void }) {
  const { t } = useTranslation();
  const [name, setName] = useState("");

  const create = useMutation({
    mutationFn: () => organizationsApi.create({ name: name.trim() }),
    onSuccess: () => {
      toast.success(t("organization.toastCreated"));
      onCreated();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <Card className="mt-8">
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <Building2 className="h-5 w-5" />
          {t("organization.createTitle")}
        </CardTitle>
        <CardDescription>{t("organization.createDesc")}</CardDescription>
      </CardHeader>
      <CardContent>
        <Label htmlFor="org-name">{t("organization.name")}</Label>
        <Input
          id="org-name"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder={t("organization.namePlaceholder")}
          className="mt-2"
        />
      </CardContent>
      <CardFooter>
        <Button
          onClick={() => create.mutate()}
          disabled={create.isPending || name.trim().length === 0}
          className="gap-2"
        >
          {create.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
          {t("organization.createAction")}
        </Button>
      </CardFooter>
    </Card>
  );
}

/** The checklist rendered straight from the server's own rule
 * (missing_identity_fields), so it can't drift from what publishing actually
 * enforces. */
function PublishReadiness({ organization }: { organization: ApiOrganization }) {
  const { t } = useTranslation();

  if (organization.identity_complete) {
    return (
      <div className="flex items-center gap-2 rounded-2xl border border-border bg-muted/30 p-4 text-sm">
        <CheckCircle2 className="h-4 w-4 text-primary" />
        {t("organization.readyToPublish")}
      </div>
    );
  }

  return (
    <div className="rounded-2xl border border-border bg-muted/30 p-4">
      <p className="flex items-center gap-2 text-sm font-medium">
        <CircleDashed className="h-4 w-4" />
        {organization.identity_required
          ? t("organization.incompleteRequired")
          : t("organization.incompleteOptional")}
      </p>
      <ul className="mt-2 space-y-1 text-sm text-muted-foreground">
        {organization.missing_identity_fields.map((field) => (
          <li key={field}>• {t(`organization.field.${field}`)}</li>
        ))}
      </ul>
    </div>
  );
}

function ReadOnlyImage({
  url,
  alt,
  square = false,
}: {
  url: string;
  alt: string;
  square?: boolean;
}) {
  const { t } = useTranslation();

  if (!url) {
    return (
      <div className="mt-2 rounded-xl border border-dashed border-border p-6 text-center text-xs text-muted-foreground">
        {t("organization.noImage")}
      </div>
    );
  }

  return (
    <img
      src={url}
      alt={alt}
      className={`mt-2 w-full rounded-xl border border-border object-cover ${
        square ? "aspect-square max-w-40" : "aspect-[16/5]"
      }`}
    />
  );
}

function IdentityCard({
  organization,
  onSaved,
}: {
  organization: ApiOrganization;
  onSaved: () => void;
}) {
  const { t } = useTranslation();
  const canEdit = organization.role === "owner" || organization.role === "admin";

  const [name, setName] = useState(organization.name);
  const [description, setDescription] = useState(organization.description ?? "");
  const [logoUrl, setLogoUrl] = useState(organization.logo_url ?? "");
  const [bannerUrl, setBannerUrl] = useState(organization.banner_url ?? "");

  // Switching organizations swaps the whole form context.
  useEffect(() => {
    setName(organization.name);
    setDescription(organization.description ?? "");
    setLogoUrl(organization.logo_url ?? "");
    setBannerUrl(organization.banner_url ?? "");
  }, [
    organization.slug,
    organization.name,
    organization.description,
    organization.logo_url,
    organization.banner_url,
  ]);

  const save = useMutation({
    mutationFn: () =>
      organizationsApi.update(organization.slug, {
        name: name.trim(),
        description: description.trim() || null,
        logo_url: logoUrl || null,
        banner_url: bannerUrl || null,
      }),
    onSuccess: () => {
      toast.success(t("organization.toastSaved"));
      onSaved();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <Building2 className="h-5 w-5" />
          {t("organization.identityTitle")}
          {organization.verified && (
            <Badge variant="secondary" className="gap-1">
              <ShieldCheck className="h-3.5 w-3.5" />
              {t("organization.verified")}
            </Badge>
          )}
        </CardTitle>
        <CardDescription>{t("organization.identityDesc")}</CardDescription>
      </CardHeader>

      <CardContent className="space-y-4">
        <div>
          <Label htmlFor="org-name-field">{t("organization.name")}</Label>
          <Input
            id="org-name-field"
            value={name}
            onChange={(e) => setName(e.target.value)}
            disabled={!canEdit}
            className="mt-2"
          />
          {/* The slug is generated once and never changes, so links an
              organizer has already shared keep working. */}
          <p className="mt-1.5 text-xs text-muted-foreground">
            {t("organization.slugNote", { slug: organization.slug })}
          </p>
        </div>

        <div>
          <Label htmlFor="org-description">{t("organization.description")}</Label>
          <Textarea
            id="org-description"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            disabled={!canEdit}
            rows={4}
            maxLength={2000}
            className="mt-2"
            placeholder={t("organization.descriptionPlaceholder")}
          />
        </div>

        {/* ImageUpload has no disabled state, so a non-admin gets a plain
            preview rather than a control that looks interactive and isn't. */}
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <Label>{t("organization.logo")}</Label>
            {canEdit ? (
              <ImageUpload
                value={logoUrl}
                onChange={(url) => setLogoUrl(url ?? "")}
                variant="logo"
              />
            ) : (
              <ReadOnlyImage url={logoUrl} alt={organization.name} square />
            )}
          </div>
          <div>
            <Label>{t("organization.banner")}</Label>
            {canEdit ? (
              <ImageUpload
                value={bannerUrl}
                onChange={(url) => setBannerUrl(url ?? "")}
                variant="banner"
              />
            ) : (
              <ReadOnlyImage url={bannerUrl} alt={organization.name} />
            )}
          </div>
        </div>
      </CardContent>

      {canEdit && (
        <CardFooter>
          <Button onClick={() => save.mutate()} disabled={save.isPending} className="gap-2">
            {save.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            {t("common.save")}
          </Button>
        </CardFooter>
      )}
    </Card>
  );
}

function ContactCard({
  organization,
  onSaved,
}: {
  organization: ApiOrganization;
  onSaved: () => void;
}) {
  const { t } = useTranslation();
  const canEdit = organization.role === "owner" || organization.role === "admin";

  const [fields, setFields] = useState({
    contact_email: organization.contact_email ?? "",
    contact_phone: organization.contact_phone ?? "",
    website: organization.website ?? "",
    facebook_url: organization.facebook_url ?? "",
    instagram_url: organization.instagram_url ?? "",
    telegram_url: organization.telegram_url ?? "",
  });

  useEffect(() => {
    setFields({
      contact_email: organization.contact_email ?? "",
      contact_phone: organization.contact_phone ?? "",
      website: organization.website ?? "",
      facebook_url: organization.facebook_url ?? "",
      instagram_url: organization.instagram_url ?? "",
      telegram_url: organization.telegram_url ?? "",
    });
  }, [organization]);

  const save = useMutation({
    mutationFn: () =>
      organizationsApi.update(
        organization.slug,
        Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, v.trim() || null])) as Record<
          string,
          string | null
        >,
      ),
    onSuccess: () => {
      toast.success(t("organization.toastSaved"));
      onSaved();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const set = (key: keyof typeof fields) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setFields((f) => ({ ...f, [key]: e.target.value }));

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t("organization.contactTitle")}</CardTitle>
        {/* Published on the public organizer page — deliberately not the
            address the organizer signs in with. */}
        <CardDescription>{t("organization.contactDesc")}</CardDescription>
      </CardHeader>

      <CardContent className="grid gap-4 sm:grid-cols-2">
        {(
          [
            ["contact_email", t("organization.contactEmail")],
            ["contact_phone", t("organization.contactPhone")],
            ["website", t("organization.website")],
            ["facebook_url", t("organization.facebook")],
            ["instagram_url", t("organization.instagram")],
            ["telegram_url", t("organization.telegram")],
          ] as const
        ).map(([key, label]) => (
          <div key={key}>
            <Label htmlFor={`org-${key}`}>{label}</Label>
            <Input
              id={`org-${key}`}
              value={fields[key]}
              onChange={set(key)}
              disabled={!canEdit}
              className="mt-2"
            />
          </div>
        ))}
      </CardContent>

      {canEdit && (
        <CardFooter>
          <Button onClick={() => save.mutate()} disabled={save.isPending} className="gap-2">
            {save.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            {t("common.save")}
          </Button>
        </CardFooter>
      )}
    </Card>
  );
}

function MembersCard({ organization }: { organization: ApiOrganization }) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const canManage = organization.role === "owner" || organization.role === "admin";

  const [email, setEmail] = useState("");
  const [role, setRole] = useState<OrganizationRole>("member");

  const membersQuery = useQuery({
    queryKey: ["organization-members", organization.slug],
    queryFn: () => organizationsApi.members(organization.slug).then((r) => r.members),
  });

  const refresh = () =>
    queryClient.invalidateQueries({ queryKey: ["organization-members", organization.slug] });

  const add = useMutation({
    mutationFn: () => organizationsApi.addMember(organization.slug, email.trim(), role),
    onSuccess: () => {
      setEmail("");
      toast.success(t("organization.toastMemberAdded"));
      refresh();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const remove = useMutation({
    mutationFn: (id: string) => organizationsApi.removeMember(organization.slug, id),
    onSuccess: () => {
      toast.success(t("organization.toastMemberRemoved"));
      refresh();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <Users className="h-5 w-5" />
          {t("organization.membersTitle")}
        </CardTitle>
        <CardDescription>{t("organization.membersDesc")}</CardDescription>
      </CardHeader>

      <CardContent className="space-y-4">
        {membersQuery.isLoading && (
          <p className="text-sm text-muted-foreground">{t("common.loading")}</p>
        )}

        <ul className="divide-y divide-border">
          {(membersQuery.data ?? []).map((member: ApiOrganizationMember) => (
            <li key={member.user_id} className="flex items-center justify-between gap-3 py-3">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium">
                  {member.display_name || member.email}
                </p>
                <p className="truncate text-xs text-muted-foreground">{member.email}</p>
              </div>
              <div className="flex shrink-0 items-center gap-2">
                <Badge variant={member.role === "owner" ? "secondary" : "outline"}>
                  {t(`organization.role.${member.role}`)}
                </Badge>
                {/* The owner has no membership row (id is null), so there is
                    nothing to remove — handing the organization over goes
                    through ownership transfer instead. */}
                {canManage && member.id && (
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled={remove.isPending}
                    onClick={() => remove.mutate(member.id!)}
                    aria-label={t("organization.removeMember")}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                )}
              </div>
            </li>
          ))}
        </ul>

        {canManage && (
          <div className="flex flex-wrap items-end gap-2 border-t border-border pt-4">
            <div className="min-w-48 flex-1">
              <Label htmlFor="org-member-email">{t("organization.addMemberEmail")}</Label>
              <Input
                id="org-member-email"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder={t("organization.addMemberPlaceholder")}
                className="mt-2"
              />
            </div>
            <Select value={role} onValueChange={(v) => setRole(v as OrganizationRole)}>
              <SelectTrigger className="w-36">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="member">{t("organization.role.member")}</SelectItem>
                <SelectItem value="admin">{t("organization.role.admin")}</SelectItem>
              </SelectContent>
            </Select>
            <Button
              onClick={() => add.mutate()}
              disabled={add.isPending || email.trim().length === 0}
              className="gap-2"
            >
              {add.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Plus className="h-4 w-4" />
              )}
              {t("organization.addMember")}
            </Button>
          </div>
        )}

        {/* No invitation flow yet — someone has to have signed up first. */}
        {canManage && (
          <p className="text-xs text-muted-foreground">{t("organization.addMemberNote")}</p>
        )}
      </CardContent>
    </Card>
  );
}

/** Owner-only. These credentials decide where registration money lands, so
 * the server rejects an admin outright rather than silently ignoring them. */
function PaymentCard({
  organization,
  onSaved,
}: {
  organization: ApiOrganization;
  onSaved: () => void;
}) {
  const { t } = useTranslation();
  const [merchantId, setMerchantId] = useState(organization.payway_merchant_id ?? "");
  const [apiKey, setApiKey] = useState("");

  useEffect(() => {
    setMerchantId(organization.payway_merchant_id ?? "");
    setApiKey("");
  }, [organization.slug, organization.payway_merchant_id]);

  const save = useMutation({
    mutationFn: () =>
      organizationsApi.update(organization.slug, {
        payway_merchant_id: merchantId.trim(),
        // Omitted when left blank so an existing key isn't overwritten by an
        // empty string just because the organizer didn't retype it.
        ...(apiKey.trim() ? { payway_api_key: apiKey.trim() } : {}),
      }),
    onSuccess: () => {
      setApiKey("");
      toast.success(t("organization.toastPaymentSaved"));
      onSaved();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const disconnect = useMutation({
    mutationFn: () =>
      organizationsApi.update(organization.slug, {
        payway_merchant_id: "",
        payway_api_key: "",
      }),
    onSuccess: () => {
      setMerchantId("");
      setApiKey("");
      toast.success(t("organization.toastPaymentDisconnected"));
      onSaved();
    },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <Card id="payment-settings" className="scroll-mt-24">
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <Wallet className="h-5 w-5" />
          {t("organization.paymentTitle")}
          {organization.payway_configured && (
            <Badge variant="secondary">{t("organization.paymentConnected")}</Badge>
          )}
        </CardTitle>
        <CardDescription>
          {t("organization.paymentDesc")}{" "}
          <a
            href="https://developer.payway.com.kh"
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-1 underline"
          >
            developer.payway.com.kh
            <ExternalLink className="h-3 w-3" />
          </a>
        </CardDescription>
      </CardHeader>

      <CardContent className="space-y-4">
        <div>
          <Label htmlFor="org-payway-merchant-id">{t("organization.merchantId")}</Label>
          <Input
            id="org-payway-merchant-id"
            value={merchantId}
            onChange={(e) => setMerchantId(e.target.value)}
            className="mt-2"
          />
        </div>
        <div>
          <Label htmlFor="org-payway-api-key">{t("organization.apiKey")}</Label>
          <Input
            id="org-payway-api-key"
            type="password"
            value={apiKey}
            onChange={(e) => setApiKey(e.target.value)}
            placeholder={
              organization.payway_api_key_masked
                ? t("organization.apiKeySaved", { masked: organization.payway_api_key_masked })
                : t("organization.apiKeyPlaceholder")
            }
            className="mt-2"
          />
        </div>
      </CardContent>

      <CardFooter className="gap-2">
        <Button
          onClick={() => save.mutate()}
          disabled={save.isPending || merchantId.trim().length === 0}
          className="gap-2"
        >
          {save.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
          {t("common.save")}
        </Button>
        {organization.payway_configured && (
          <Button
            variant="outline"
            onClick={() => disconnect.mutate()}
            disabled={disconnect.isPending}
          >
            {t("organization.disconnect")}
          </Button>
        )}
      </CardFooter>
    </Card>
  );
}
