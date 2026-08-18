import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import {
  Loader2,
  Wallet,
  ShieldCheck,
  ExternalLink,
  KeyRound,
  Mail,
  Bell,
  Trash2,
} from "lucide-react";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import { profileApi, authApi } from "@/lib/api-client";
import { useAuth } from "@/lib/use-auth";
import { SiteHeader } from "@/components/site-header";
import { ImageUpload } from "@/components/image-upload";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
  CardFooter,
} from "@/components/ui/card";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";

export const Route = createFileRoute("/_authenticated/profile")({
  head: () => ({ meta: [{ title: "Your profile — Rally" }] }),
  component: ProfilePage,
});

function ProfilePage() {
  const { t } = useTranslation();
  const { user, refresh, signOut } = useAuth();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const profileQuery = useQuery({
    queryKey: ["profile"],
    queryFn: async () => {
      const { profile } = await profileApi.get();
      return profile;
    },
  });

  const profile = profileQuery.data;

  // ── Basic info ──
  const [displayName, setDisplayName] = useState<string | null>(null);
  const [avatarUrl, setAvatarUrl] = useState<string | null | undefined>(undefined);

  if (profile && displayName === null) setDisplayName(profile.display_name ?? "");
  if (profile && avatarUrl === undefined) setAvatarUrl(profile.avatar_url ?? null);

  const saveProfile = useMutation({
    mutationFn: () =>
      profileApi.update({
        display_name: displayName ?? "",
        avatar_url: avatarUrl ?? null,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["profile"] });
      // Display name / avatar are also shown in the header — refresh the
      // auth user so it updates immediately instead of on next reload.
      refresh();
      toast.success(t("profile.toastProfileSaved"));
    },
    onError: (e: any) => toast.error(e.message ?? t("profile.toastProfileSaveError")),
  });

  // ── PayWay credentials ──
  const [merchantId, setMerchantId] = useState<string | null>(null);
  const [apiKey, setApiKey] = useState("");

  if (profile && merchantId === null) setMerchantId(profile.payway_merchant_id ?? "");

  const savePayway = useMutation({
    mutationFn: () =>
      profileApi.update({
        payway_merchant_id: merchantId ?? "",
        // Blank means "leave the saved key unchanged" — omit it entirely so
        // the backend doesn't overwrite it with an empty value.
        payway_api_key: apiKey.trim() || undefined,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["profile"] });
      setApiKey("");
      toast.success(t("profile.toastPaymentSaved"));
    },
    onError: (e: any) => toast.error(e.message ?? t("profile.toastPaymentSaveError")),
  });

  const disconnectPayway = useMutation({
    mutationFn: () => profileApi.update({ payway_merchant_id: "", payway_api_key: "" }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["profile"] });
      setMerchantId("");
      setApiKey("");
      toast.success(t("profile.toastDisconnected"));
    },
    onError: (e: any) => toast.error(e.message ?? t("profile.toastDisconnectError")),
  });

  // ── Change password ──
  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [newPasswordConfirmation, setNewPasswordConfirmation] = useState("");

  const changePassword = useMutation({
    mutationFn: () => authApi.changePassword(currentPassword, newPassword),
    onSuccess: () => {
      setCurrentPassword("");
      setNewPassword("");
      setNewPasswordConfirmation("");
      toast.success(t("profile.toastPasswordChanged"));
    },
    onError: (e: any) => toast.error(e.message ?? t("profile.toastPasswordChangeError")),
  });

  // ── Change email ──
  const [newEmail, setNewEmail] = useState("");
  const [emailCurrentPassword, setEmailCurrentPassword] = useState("");

  const changeEmail = useMutation({
    mutationFn: () => authApi.changeEmail(emailCurrentPassword, newEmail),
    onSuccess: () => {
      setNewEmail("");
      setEmailCurrentPassword("");
      refresh();
      toast.success(t("profile.toastEmailChanged"));
    },
    onError: (e: any) => toast.error(e.message ?? t("profile.toastEmailChangeError")),
  });

  // ── Notification preferences ──
  const [notifyPaymentReceived, setNotifyPaymentReceived] = useState<boolean | null>(null);
  const [notifyRefundIssued, setNotifyRefundIssued] = useState<boolean | null>(null);
  const [notifyPromotedFromWaitlist, setNotifyPromotedFromWaitlist] = useState<boolean | null>(
    null,
  );

  if (profile && notifyPaymentReceived === null) {
    setNotifyPaymentReceived(profile.notify_payment_received);
  }
  if (profile && notifyRefundIssued === null) setNotifyRefundIssued(profile.notify_refund_issued);
  if (profile && notifyPromotedFromWaitlist === null) {
    setNotifyPromotedFromWaitlist(profile.notify_promoted_from_waitlist);
  }

  const saveNotifications = useMutation({
    mutationFn: () =>
      profileApi.update({
        notify_payment_received: notifyPaymentReceived ?? true,
        notify_refund_issued: notifyRefundIssued ?? true,
        notify_promoted_from_waitlist: notifyPromotedFromWaitlist ?? true,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["profile"] });
      toast.success(t("profile.toastNotificationsSaved"));
    },
    onError: (e: any) => toast.error(e.message ?? t("profile.toastNotificationsSaveError")),
  });

  // ── Delete account ──
  const [deletePassword, setDeletePassword] = useState("");
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);

  const deleteAccount = useMutation({
    mutationFn: () => authApi.deleteAccount(deletePassword),
    onSuccess: () => {
      setDeleteDialogOpen(false);
      signOut();
      toast.success(t("profile.toastAccountDeleted"));
      navigate({ to: "/" });
    },
    onError: (e: any) => toast.error(e.message ?? t("profile.toastAccountDeleteError")),
  });

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />
      <main className="mx-auto max-w-2xl px-5 py-10">
        <div>
          <h1 className="font-display text-3xl font-bold">{t("profile.title")}</h1>
          <p className="mt-1 text-muted-foreground">{user?.email}</p>
        </div>

        {profileQuery.isLoading && (
          <p className="mt-6 text-muted-foreground">{t("common.loading")}</p>
        )}
        {profileQuery.isError && (
          <div className="mt-6 rounded-2xl border border-destructive/30 bg-destructive/5 p-6 text-center">
            <p className="font-medium text-destructive">{t("profile.loadError")}</p>
            <Button
              variant="outline"
              size="sm"
              className="mt-4"
              onClick={() => profileQuery.refetch()}
            >
              {t("common.tryAgain")}
            </Button>
          </div>
        )}

        {profile && (
          <div className="mt-8 space-y-6">
            {/* Basic info */}
            <Card>
              <CardHeader>
                <CardTitle>{t("profile.basicInfoTitle")}</CardTitle>
                <CardDescription>{t("profile.basicInfoDesc")}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-5">
                <ImageUpload
                  value={avatarUrl ?? null}
                  onChange={setAvatarUrl}
                  variant="avatar"
                  label={t("profile.avatar")}
                />
                <div className="space-y-2">
                  <Label htmlFor="display-name">{t("profile.displayName")}</Label>
                  <Input
                    id="display-name"
                    value={displayName ?? ""}
                    onChange={(e) => setDisplayName(e.target.value)}
                    placeholder={t("profile.displayNamePlaceholder")}
                  />
                </div>
              </CardContent>
              <CardFooter>
                <Button onClick={() => saveProfile.mutate()} disabled={saveProfile.isPending}>
                  {saveProfile.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                  {t("profile.saveProfile")}
                </Button>
              </CardFooter>
            </Card>

            {/* Payment settings */}
            <Card id="payment-settings" className="scroll-mt-24">
              <CardHeader>
                <div className="flex items-center gap-2">
                  <Wallet className="h-5 w-5 text-muted-foreground" />
                  <CardTitle>{t("header.paymentSettings")}</CardTitle>
                  {profile.payway_configured && (
                    <Badge variant="default" className="gap-1">
                      <ShieldCheck className="h-3 w-3" /> {t("profile.connected")}
                    </Badge>
                  )}
                </div>
                <CardDescription>
                  {t("profile.connectPrefix")}{" "}
                  <a
                    href="https://developer.payway.com.kh"
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex items-center gap-0.5 underline underline-offset-2 hover:text-foreground"
                  >
                    ABA PayWay
                    <ExternalLink className="h-3 w-3" />
                  </a>{" "}
                  {t("profile.connectSuffix")}
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-5">
                <div className="space-y-2">
                  <Label htmlFor="payway-merchant-id">{t("profile.merchantId")}</Label>
                  <Input
                    id="payway-merchant-id"
                    value={merchantId ?? ""}
                    onChange={(e) => setMerchantId(e.target.value)}
                    placeholder={t("profile.merchantIdPlaceholder")}
                    autoComplete="off"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="payway-api-key">{t("profile.apiKey")}</Label>
                  <Input
                    id="payway-api-key"
                    type="password"
                    value={apiKey}
                    onChange={(e) => setApiKey(e.target.value)}
                    placeholder={
                      profile.payway_api_key_masked
                        ? t("profile.apiKeySavedPlaceholder", {
                            masked: profile.payway_api_key_masked,
                          })
                        : t("profile.apiKeyPlaceholder")
                    }
                    autoComplete="off"
                  />
                  <p className="text-xs text-muted-foreground">{t("profile.apiKeyNote")}</p>
                </div>
              </CardContent>
              <CardFooter className="gap-2">
                <Button onClick={() => savePayway.mutate()} disabled={savePayway.isPending}>
                  {savePayway.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                  {t("profile.savePaymentSettings")}
                </Button>
                {profile.payway_configured && (
                  <Button
                    variant="outline"
                    onClick={() => disconnectPayway.mutate()}
                    disabled={disconnectPayway.isPending}
                  >
                    {disconnectPayway.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                    {t("profile.disconnect")}
                  </Button>
                )}
              </CardFooter>
            </Card>

            {/* Change password */}
            <Card>
              <CardHeader>
                <div className="flex items-center gap-2">
                  <KeyRound className="h-5 w-5 text-muted-foreground" />
                  <CardTitle>{t("profile.changePasswordTitle")}</CardTitle>
                </div>
                <CardDescription>{t("profile.changePasswordDesc")}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="current-password">{t("profile.currentPassword")}</Label>
                  <Input
                    id="current-password"
                    type="password"
                    value={currentPassword}
                    onChange={(e) => setCurrentPassword(e.target.value)}
                    autoComplete="current-password"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="new-password">{t("profile.newPassword")}</Label>
                  <Input
                    id="new-password"
                    type="password"
                    value={newPassword}
                    onChange={(e) => setNewPassword(e.target.value)}
                    autoComplete="new-password"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="new-password-confirmation">
                    {t("profile.newPasswordConfirmation")}
                  </Label>
                  <Input
                    id="new-password-confirmation"
                    type="password"
                    value={newPasswordConfirmation}
                    onChange={(e) => setNewPasswordConfirmation(e.target.value)}
                    autoComplete="new-password"
                  />
                </div>
              </CardContent>
              <CardFooter>
                <Button
                  onClick={() => changePassword.mutate()}
                  disabled={
                    changePassword.isPending ||
                    !currentPassword ||
                    !newPassword ||
                    newPassword !== newPasswordConfirmation
                  }
                >
                  {changePassword.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                  {t("profile.changePasswordButton")}
                </Button>
              </CardFooter>
            </Card>

            {/* Change email */}
            <Card>
              <CardHeader>
                <div className="flex items-center gap-2">
                  <Mail className="h-5 w-5 text-muted-foreground" />
                  <CardTitle>{t("profile.changeEmailTitle")}</CardTitle>
                </div>
                <CardDescription>{t("profile.changeEmailDesc", { email: user?.email })}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="new-email">{t("profile.newEmail")}</Label>
                  <Input
                    id="new-email"
                    type="email"
                    value={newEmail}
                    onChange={(e) => setNewEmail(e.target.value)}
                    placeholder={t("profile.newEmailPlaceholder")}
                    autoComplete="email"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="email-current-password">{t("profile.currentPassword")}</Label>
                  <Input
                    id="email-current-password"
                    type="password"
                    value={emailCurrentPassword}
                    onChange={(e) => setEmailCurrentPassword(e.target.value)}
                    autoComplete="current-password"
                  />
                </div>
              </CardContent>
              <CardFooter>
                <Button
                  onClick={() => changeEmail.mutate()}
                  disabled={changeEmail.isPending || !newEmail || !emailCurrentPassword}
                >
                  {changeEmail.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                  {t("profile.changeEmailButton")}
                </Button>
              </CardFooter>
            </Card>

            {/* Notification preferences */}
            <Card>
              <CardHeader>
                <div className="flex items-center gap-2">
                  <Bell className="h-5 w-5 text-muted-foreground" />
                  <CardTitle>{t("profile.notificationsTitle")}</CardTitle>
                </div>
                <CardDescription>{t("profile.notificationsDesc")}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="flex items-center justify-between gap-4">
                  <div>
                    <p className="text-sm font-medium">{t("profile.notifyPaymentReceived")}</p>
                    <p className="text-xs text-muted-foreground">
                      {t("profile.notifyPaymentReceivedDesc")}
                    </p>
                  </div>
                  <Switch
                    checked={notifyPaymentReceived ?? true}
                    onCheckedChange={setNotifyPaymentReceived}
                  />
                </div>
                <div className="flex items-center justify-between gap-4">
                  <div>
                    <p className="text-sm font-medium">{t("profile.notifyRefundIssued")}</p>
                    <p className="text-xs text-muted-foreground">
                      {t("profile.notifyRefundIssuedDesc")}
                    </p>
                  </div>
                  <Switch
                    checked={notifyRefundIssued ?? true}
                    onCheckedChange={setNotifyRefundIssued}
                  />
                </div>
                <div className="flex items-center justify-between gap-4">
                  <div>
                    <p className="text-sm font-medium">
                      {t("profile.notifyPromotedFromWaitlist")}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {t("profile.notifyPromotedFromWaitlistDesc")}
                    </p>
                  </div>
                  <Switch
                    checked={notifyPromotedFromWaitlist ?? true}
                    onCheckedChange={setNotifyPromotedFromWaitlist}
                  />
                </div>
              </CardContent>
              <CardFooter>
                <Button
                  onClick={() => saveNotifications.mutate()}
                  disabled={saveNotifications.isPending}
                >
                  {saveNotifications.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                  {t("profile.saveNotifications")}
                </Button>
              </CardFooter>
            </Card>

            {/* Danger zone */}
            <Card className="border-destructive/30">
              <CardHeader>
                <CardTitle className="text-destructive">{t("profile.dangerZoneTitle")}</CardTitle>
                <CardDescription>{t("profile.dangerZoneDesc")}</CardDescription>
              </CardHeader>
              <CardFooter>
                <AlertDialog open={deleteDialogOpen} onOpenChange={setDeleteDialogOpen}>
                  <AlertDialogTrigger asChild>
                    <Button variant="destructive">
                      <Trash2 className="h-4 w-4" /> {t("profile.deleteAccountButton")}
                    </Button>
                  </AlertDialogTrigger>
                  <AlertDialogContent>
                    <AlertDialogHeader>
                      <AlertDialogTitle>{t("profile.deleteDialogTitle")}</AlertDialogTitle>
                      <AlertDialogDescription>
                        {t("profile.deleteDialogDesc")}
                      </AlertDialogDescription>
                    </AlertDialogHeader>
                    <div className="space-y-2 py-2">
                      <Label htmlFor="delete-current-password">
                        {t("profile.currentPassword")}
                      </Label>
                      <Input
                        id="delete-current-password"
                        type="password"
                        value={deletePassword}
                        onChange={(e) => setDeletePassword(e.target.value)}
                        autoComplete="current-password"
                      />
                    </div>
                    <AlertDialogFooter>
                      <AlertDialogCancel onClick={() => setDeletePassword("")}>
                        {t("common.cancel")}
                      </AlertDialogCancel>
                      <AlertDialogAction
                        disabled={!deletePassword || deleteAccount.isPending}
                        onClick={(e) => {
                          e.preventDefault();
                          deleteAccount.mutate();
                        }}
                      >
                        {deleteAccount.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                        {t("profile.deleteDialogConfirm")}
                      </AlertDialogAction>
                    </AlertDialogFooter>
                  </AlertDialogContent>
                </AlertDialog>
              </CardFooter>
            </Card>
          </div>
        )}
      </main>
    </div>
  );
}
