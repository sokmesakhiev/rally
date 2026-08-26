/**
 * MembersTab — the event's team: pending invitations plus accepted members,
 * with an invite form and per-member role/remove controls for the owner.
 *
 * Owner-only management (`canManage`), everyone else gets a read-only
 * roster — mirrors EventAuthorization::CAPABILITIES' :manage_members entry
 * (owner-only, deliberately, even for Manager — see that concern's
 * comment: letting a Manager add/remove Managers would let the owner get
 * diluted out of their own event with no audit trail they'd notice).
 *
 * Like PaidEventGate, this is purely a UI affordance — hiding the invite
 * form/role selects/remove buttons here doesn't grant or deny anything by
 * itself. Every mutation below still gets checked server-side
 * (EventInvitationsController/EventMembersController), and a request this
 * component would never send is exactly as forbidden as one crafted by hand.
 *
 * A member (any role) may always remove *themselves* (leave) — that's not
 * gated on `canManage`, since EventMembersController#destroy's self-removal
 * branch isn't owner-only either.
 */
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import { Mail, Loader2, Trash2, Crown } from "lucide-react";
import {
  eventMembersApi,
  eventInvitationsApi,
  type ApiEventMember,
} from "@/lib/api-client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
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
import { memberRoleLabel, EVENT_MEMBER_ROLE_VALUES, formatDate } from "@/lib/event-utils";

interface MembersTabProps {
  eventId: string;
  canManage: boolean;
  currentUserId: string;
}

export function MembersTab({ eventId, canManage, currentUserId }: MembersTabProps) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();

  const membersQuery = useQuery({
    queryKey: ["event-members", eventId],
    queryFn: () => eventMembersApi.list(eventId).then((r) => r.members),
  });

  // Pending invitations are owner-only (EventInvitationsController#index) —
  // don't even issue the request for a Manager/Viewer, who'd just get a 403.
  const invitationsQuery = useQuery({
    queryKey: ["event-invitations", eventId],
    queryFn: () => eventInvitationsApi.list(eventId).then((r) => r.invitations),
    enabled: canManage,
  });

  const members = membersQuery.data ?? [];
  const invitations = invitationsQuery.data ?? [];

  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteRole, setInviteRole] = useState<string>("viewer");

  const invalidateAll = () => {
    queryClient.invalidateQueries({ queryKey: ["event-members", eventId] });
    queryClient.invalidateQueries({ queryKey: ["event-invitations", eventId] });
    queryClient.invalidateQueries({ queryKey: ["event-activity", eventId] });
  };

  const invite = useMutation({
    mutationFn: () => eventInvitationsApi.create(eventId, inviteEmail.trim(), inviteRole),
    onSuccess: () => {
      setInviteEmail("");
      invalidateAll();
      toast.success(t("membersTab.toastInvited"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const revoke = useMutation({
    mutationFn: (invitationId: string) => eventInvitationsApi.revoke(eventId, invitationId),
    onSuccess: () => {
      invalidateAll();
      toast.success(t("membersTab.toastRevoked"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const changeRole = useMutation({
    mutationFn: ({ membershipId, role }: { membershipId: string; role: string }) =>
      eventMembersApi.updateRole(eventId, membershipId, role),
    onSuccess: () => {
      invalidateAll();
      toast.success(t("membersTab.toastRoleChanged"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const removeMember = useMutation({
    mutationFn: (membershipId: string) => eventMembersApi.remove(eventId, membershipId),
    onSuccess: (_data, membershipId) => {
      const wasSelf = members.find((m) => m.id === membershipId)?.user_id === currentUserId;
      invalidateAll();
      toast.success(wasSelf ? t("membersTab.toastLeft") : t("membersTab.toastRemoved"));
    },
    onError: (e: any) => toast.error(e.message),
  });

  const handleInvite = (e: React.FormEvent) => {
    e.preventDefault();
    if (!inviteEmail.trim()) return;
    invite.mutate();
  };

  return (
    <div className="space-y-6">
      {canManage && (
        <div className="rounded-2xl border border-border bg-card p-6">
          <div className="mb-1 flex items-center gap-2">
            <Mail className="h-5 w-5 text-muted-foreground" />
            <h2 className="font-semibold">{t("membersTab.inviteTitle")}</h2>
          </div>
          <p className="mb-4 text-sm text-muted-foreground">{t("membersTab.inviteDesc")}</p>

          <form onSubmit={handleInvite} className="flex flex-wrap items-end gap-3">
            <div className="min-w-[220px] flex-1 space-y-1.5">
              <Label htmlFor="invite-email">{t("membersTab.emailLabel")}</Label>
              <Input
                id="invite-email"
                type="email"
                required
                value={inviteEmail}
                onChange={(e) => setInviteEmail(e.target.value)}
                placeholder={t("membersTab.emailPlaceholder")}
              />
            </div>
            <div className="w-40 space-y-1.5">
              <Label>{t("membersTab.roleLabel")}</Label>
              <Select value={inviteRole} onValueChange={setInviteRole}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {EVENT_MEMBER_ROLE_VALUES.map((role) => (
                    <SelectItem key={role} value={role}>
                      {memberRoleLabel(role)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <Button type="submit" disabled={invite.isPending || !inviteEmail.trim()}>
              {invite.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
              {t("membersTab.inviteButton")}
            </Button>
          </form>
        </div>
      )}

      {canManage && (
        <div className="overflow-hidden rounded-2xl border border-border">
          <div className="border-b border-border bg-muted/40 px-5 py-3">
            <p className="text-sm font-semibold">{t("membersTab.pendingTitle")}</p>
          </div>
          {invitationsQuery.isLoading && (
            <p className="p-5 text-sm text-muted-foreground">{t("common.loading")}</p>
          )}
          {!invitationsQuery.isLoading && invitations.length === 0 && (
            <p className="p-6 text-center text-sm text-muted-foreground">
              {t("membersTab.noPending")}
            </p>
          )}
          {invitations.length > 0 && (
            <div className="divide-y divide-border">
              {invitations.map((inv) => (
                <div
                  key={inv.id}
                  className="flex flex-wrap items-center justify-between gap-3 p-4"
                >
                  <div className="min-w-0">
                    <p className="truncate font-medium">{inv.email}</p>
                    <p className="text-xs text-muted-foreground">
                      {t("membersTab.invitedAs", { role: memberRoleLabel(inv.role) })}
                      {" · "}
                      {t("membersTab.expiresOn", { date: formatDate(inv.expires_at) })}
                    </p>
                  </div>
                  <Button
                    variant="ghost"
                    size="sm"
                    disabled={revoke.isPending}
                    onClick={() => revoke.mutate(inv.id)}
                  >
                    <Trash2 className="h-4 w-4" /> {t("membersTab.revokeButton")}
                  </Button>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      <div className="overflow-hidden rounded-2xl border border-border">
        <div className="border-b border-border bg-muted/40 px-5 py-3">
          <p className="text-sm font-semibold">{t("membersTab.rosterTitle")}</p>
        </div>
        {membersQuery.isLoading && (
          <p className="p-5 text-sm text-muted-foreground">{t("common.loading")}</p>
        )}
        {!membersQuery.isLoading && (
          <div className="divide-y divide-border">
            {members.map((m) => (
              <MemberRow
                key={m.id ?? m.user_id}
                member={m}
                canManage={canManage}
                isSelf={m.user_id === currentUserId}
                onChangeRole={(role) => m.id && changeRole.mutate({ membershipId: m.id, role })}
                onRemove={() => m.id && removeMember.mutate(m.id)}
                removePending={removeMember.isPending}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function MemberRow({
  member,
  canManage,
  isSelf,
  onChangeRole,
  onRemove,
  removePending,
}: {
  member: ApiEventMember;
  canManage: boolean;
  isSelf: boolean;
  onChangeRole: (role: string) => void;
  onRemove: () => void;
  removePending: boolean;
}) {
  const { t } = useTranslation();
  // Anyone may leave on their own; only the owner may remove someone else
  // or change another member's role — see this file's class comment.
  const mayRemove = member.role !== "owner" && member.id && (canManage || isSelf);

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 p-4">
      <div className="min-w-0">
        <p className="truncate font-medium">
          {member.display_name ?? t("membersTab.memberFallback")}
          {isSelf && ` (${t("membersTab.youSuffix")})`}
        </p>
        <p className="text-xs text-muted-foreground">
          {t("membersTab.joinedOn", { date: formatDate(member.joined_at) })}
        </p>
      </div>

      <div className="flex items-center gap-2">
        {member.role === "owner" ? (
          <Badge variant="secondary" className="gap-1">
            <Crown className="h-3 w-3" /> {t("membersTab.ownerBadge")}
          </Badge>
        ) : canManage ? (
          <Select value={member.role} onValueChange={onChangeRole}>
            <SelectTrigger className="h-8 w-36 text-xs">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {EVENT_MEMBER_ROLE_VALUES.map((role) => (
                <SelectItem key={role} value={role}>
                  {memberRoleLabel(role)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        ) : (
          <Badge variant="outline">{memberRoleLabel(member.role)}</Badge>
        )}

        {mayRemove && (
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button variant="ghost" size="sm">
                <Trash2 className="h-4 w-4" />
              </Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>
                  {isSelf ? t("membersTab.leaveDialogTitle") : t("membersTab.removeDialogTitle")}
                </AlertDialogTitle>
                <AlertDialogDescription>
                  {isSelf
                    ? t("membersTab.leaveDialogDesc")
                    : t("membersTab.removeDialogDesc", {
                        name: member.display_name ?? t("membersTab.memberFallback"),
                      })}
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>{t("common.cancel")}</AlertDialogCancel>
                <AlertDialogAction disabled={removePending} onClick={onRemove}>
                  {isSelf ? t("membersTab.leaveButton") : t("common.remove")}
                </AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        )}
      </div>
    </div>
  );
}
