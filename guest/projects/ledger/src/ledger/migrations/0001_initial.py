from django.db import migrations, models

from ledger.constants import ACCOUNT_BALANCE, ACCOUNT_NAMES


def accounts_create(apps, schema_editor):
    account = apps.get_model("ledger", "Account")
    accounts = [account(balance=ACCOUNT_BALANCE, name=name) for name in ACCOUNT_NAMES]

    account.objects.bulk_create(accounts)


class Migration(migrations.Migration):
    dependencies = []
    initial = True

    operations = [
        migrations.CreateModel(
            name="Account",
            fields=[
                (
                    "id",
                    models.BigAutoField(
                        auto_created=True,
                        primary_key=True,
                        serialize=False,
                        verbose_name="ID",
                    ),
                ),
                ("balance", models.BigIntegerField()),
                ("name", models.CharField(max_length=32, unique=True)),
            ],
        ),
        migrations.CreateModel(
            name="Transfer",
            fields=[
                ("amount", models.BigIntegerField()),
                ("created", models.DateTimeField(auto_now_add=True)),
                ("id", models.UUIDField(primary_key=True, serialize=False)),
                (
                    "source",
                    models.ForeignKey(
                        on_delete=models.PROTECT,
                        related_name="outgoing",
                        to="ledger.account",
                    ),
                ),
                (
                    "target",
                    models.ForeignKey(
                        on_delete=models.PROTECT,
                        related_name="incoming",
                        to="ledger.account",
                    ),
                ),
            ],
        ),
        migrations.RunPython(accounts_create),
    ]
