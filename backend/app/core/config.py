from pydantic import Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = Field(
        "postgresql://postgres:hershey@localhost:5432/pettrackcare",
        env="DATABASE_URL",
    )
    jwt_secret_key: str = Field("replace-with-a-secret", env="JWT_SECRET_KEY")
    jwt_algorithm: str = Field("HS256", env="JWT_ALGORITHM")
    access_token_expire_minutes: int = Field(60, env="ACCESS_TOKEN_EXPIRE_MINUTES")
    default_admin_email: str = Field("admin@pettrackcare.local", env="DEFAULT_ADMIN_EMAIL")
    default_admin_password: str = Field("AdminPass123!", env="DEFAULT_ADMIN_PASSWORD")
    default_admin_name: str = Field("PetTrackCare Admin", env="DEFAULT_ADMIN_NAME")

    def create_postgres_url(self) -> str:
        return self.database_url


settings = Settings()
