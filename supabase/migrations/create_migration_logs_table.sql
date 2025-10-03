-- Optional: Create migration_logs table for monitoring automatic migrations
-- This table is optional - the auto-migration will work without it
CREATE TABLE IF NOT EXISTS migration_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    migration_type TEXT NOT NULL,
    success_count INTEGER DEFAULT 0,
    failed_count INTEGER DEFAULT 0,
    error_details TEXT,
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create index for better performance
CREATE INDEX IF NOT EXISTS idx_migration_logs_user_id ON migration_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_migration_logs_timestamp ON migration_logs(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_migration_logs_type ON migration_logs(migration_type);

-- Enable RLS
ALTER TABLE migration_logs ENABLE ROW LEVEL SECURITY;

-- Policy to allow users to view their own migration logs
CREATE POLICY "Users can view their migration logs" ON migration_logs
    FOR SELECT USING (user_id = auth.uid());

-- Policy to allow system to insert migration logs
CREATE POLICY "System can insert migration logs" ON migration_logs
    FOR INSERT WITH CHECK (true);

-- Add comments for documentation
COMMENT ON TABLE migration_logs IS 'Logs automatic Firebase to Supabase migrations for monitoring';
COMMENT ON COLUMN migration_logs.user_id IS 'User who triggered the migration';
COMMENT ON COLUMN migration_logs.migration_type IS 'Type of migration (e.g., auto_firebase_sync)';
COMMENT ON COLUMN migration_logs.success_count IS 'Number of successfully migrated records';
COMMENT ON COLUMN migration_logs.failed_count IS 'Number of failed migration attempts';
COMMENT ON COLUMN migration_logs.error_details IS 'Details of any errors that occurred';