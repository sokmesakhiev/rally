for name in database-url jwt-secret rails-master-key aba-payway-merchant-id aba-payway-api-key recaptcha-secret-key; do
  aws secretsmanager delete-secret \
    --secret-id "rally-production/$name" \
    --force-delete-without-recovery
done
