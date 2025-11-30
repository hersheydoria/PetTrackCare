-- Create pet_locations table for storing pet location data migrated from Firebase
CREATE TABLE IF NOT EXISTS pet_locations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pet_id TEXT NOT NULL,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    address TEXT,
    timestamp TIMESTAMPTZ,
    additional_data JSONB, -- Store any additional Firebase data here
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_pet_locations_pet_id ON pet_locations(pet_id);
CREATE INDEX IF NOT EXISTS idx_pet_locations_timestamp ON pet_locations(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_pet_locations_created_at ON pet_locations(created_at DESC);

-- Create RLS (Row Level Security) policies
ALTER TABLE pet_locations ENABLE ROW LEVEL SECURITY;

-- Policy to allow users to see locations for their own pets
CREATE POLICY "Users can view their pet locations" ON pet_locations
    FOR SELECT USING (
        pet_id IN (
            SELECT id::text FROM pets 
            WHERE owner_id = auth.uid()::text
        )
    );

-- Policy to allow users to insert/update locations for their own pets
CREATE POLICY "Users can insert/update their pet locations" ON pet_locations
    FOR ALL USING (
        pet_id IN (
            SELECT id::text FROM pets 
            WHERE owner_id = auth.uid()::text
        )
    );

-- Add a function to automatically update the updated_at timestamp
CREATE OR REPLACE FUNCTION update_pet_locations_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for the update function
CREATE TRIGGER update_pet_locations_updated_at
    BEFORE UPDATE ON pet_locations
    FOR EACH ROW
    EXECUTE FUNCTION update_pet_locations_updated_at();

-- Add comments for documentation
COMMENT ON TABLE pet_locations IS 'Stores location data for pets, migrated from Firebase Realtime Database';
COMMENT ON COLUMN pet_locations.pet_id IS 'References the pet ID from the pets table';
COMMENT ON COLUMN pet_locations.latitude IS 'GPS latitude coordinate';
COMMENT ON COLUMN pet_locations.longitude IS 'GPS longitude coordinate';
COMMENT ON COLUMN pet_locations.address IS 'Human-readable address (optional)';
COMMENT ON COLUMN pet_locations.timestamp IS 'When the location data was recorded';
COMMENT ON COLUMN pet_locations.additional_data IS 'Any additional data from Firebase stored as JSON';