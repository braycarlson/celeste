from django.db import models


class Account(models.Model):
    balance = models.BigIntegerField()
    name = models.CharField(max_length=32, unique=True)


class Rejection(models.Model):
    created = models.DateTimeField(auto_now_add=True)
    id = models.UUIDField(primary_key=True)
    reason = models.CharField(max_length=32)


class Transfer(models.Model):
    amount = models.BigIntegerField()
    created = models.DateTimeField(auto_now_add=True)
    id = models.UUIDField(primary_key=True)
    source = models.ForeignKey(Account, on_delete=models.PROTECT, related_name="outgoing")
    target = models.ForeignKey(Account, on_delete=models.PROTECT, related_name="incoming")
