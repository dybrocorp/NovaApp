CREATE TABLE device_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nova_id TEXT
);
