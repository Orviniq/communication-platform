import uuid

from django.contrib.auth.models import AbstractBaseUser, BaseUserManager, PermissionsMixin
from django.core.validators import RegexValidator
from django.db import models

from core.buckets import PROFILE_BUCKETS
from core.fields import OpaqueBlobField

username_validator = RegexValidator(
    r"^[a-z0-9_]{3,32}$", "3–32 chars: lowercase letters, digits, underscore."
)


class UserManager(BaseUserManager):
    def create_user(self, username, password=None, **extra):
        if not username:
            raise ValueError("username required")
        username = username.lower()
        user = self.model(username=username, **extra)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_superuser(self, username, password=None, **extra):
        extra.setdefault("is_staff", True)
        extra.setdefault("is_superuser", True)
        extra.setdefault("is_active", True)  # operator account
        return self.create_user(username, password, **extra)


class User(AbstractBaseUser, PermissionsMixin):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    username = models.CharField(
        max_length=32, unique=True, validators=[username_validator]
    )
    is_active = models.BooleanField(default=False)  # the owner activates accounts
    is_staff = models.BooleanField(default=False)
    created_date = models.DateField(auto_now_add=True)

    USERNAME_FIELD = "username"
    objects = UserManager()

    def save(self, *args, **kwargs):
        self.username = self.username.lower()
        super().save(*args, **kwargs)


class ProfileBlob(models.Model):
    user = models.OneToOneField(
        User, on_delete=models.CASCADE, primary_key=True, related_name="profile"
    )
    blob = OpaqueBlobField(bucket_set=PROFILE_BUCKETS)
    version = models.PositiveIntegerField(default=0)
