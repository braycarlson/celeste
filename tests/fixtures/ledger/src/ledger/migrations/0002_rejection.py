from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("ledger", "0001_initial")]

    operations = [
        migrations.CreateModel(
            name="Rejection",
            fields=[
                ("created", models.DateTimeField(auto_now_add=True)),
                ("id", models.UUIDField(primary_key=True, serialize=False)),
                ("reason", models.CharField(max_length=32)),
            ],
        ),
    ]
