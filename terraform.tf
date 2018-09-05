variable "app_id" {}
variable "app_name" {}
variable "aws_profile" {}
variable "identity_pool_name" {}
variable "user_pool_name" {}
variable "bucket_name" {}
variable "role_name_prefix" {}
variable "env" {
  default = "dev"
}
variable "aws_region" {
  default = "eu-central-1"
}

provider "aws" {
  region     = "${var.aws_region}"
  profile    = "${var.aws_profile}"
}

resource "aws_s3_bucket" "webapp" {
  bucket = "${var.bucket_name}"
  acl    = "private"

  tags {
    Name = "${var.app_name}"
    Environment = "${var.env}"
  }
}

## create dynamodb tables
resource "aws_dynamodb_table" "logintrail" {
  name           = "${var.app_id}-logintrail"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "userId"
  range_key      = "activityDate"

  attribute {
    name = "userId"
    type = "S"
  }

  attribute {
    name = "activityDate"
    type = "S"
  }

  #  ttl {
  #    attribute_name = "TimeToExist"
  #    enabled = false
  #  }

  tags {
    Name = "${var.app_name}"
    Environment = "${var.env}"
  }
}

# Create the user pool
resource "aws_cognito_user_pool" "main" {
  name = "${var.user_pool_name}"
  tags {
    Name = "${var.app_name}"
    Environment = "${var.env}"
  }
}

# Create the user pool client
#$aws_cmd cognito-idp create-user-pool-client --user-pool-id $USER_POOL_ID --no-generate-secret --client-name webapp --region $REGION > /tmp/$POOL_NAME-create-user-pool-client
#USER_POOL_CLIENT_ID=$(grep -E '"ClientId":' /tmp/$POOL_NAME-create-user-pool-client | awk -F'"' '{print $4}')
resource "aws_cognito_user_pool_client" "main" {
  name = "webapp"
  generate_secret = false
  user_pool_id = "${aws_cognito_user_pool.main.id}"
}

# Add the user pool and user pool client id to the identity pool
#$aws_cmd cognito-identity update-identity-pool --allow-unauthenticated-identities --identity-pool-id $IDENTITY_POOL_ID --identity-pool-name $IDENTITY_POOL_NAME \
#--cognito-identity-providers ProviderName=cognito-idp.$REGION.amazonaws.com/$USER_POOL_ID,ClientId=$USER_POOL_CLIENT_ID --region $REGION \
#> /tmp/$IDENTITY_POOL_ID-add-user-pool
resource "aws_cognito_identity_pool" "main" {
  identity_pool_name = "${var.identity_pool_name}"
  allow_unauthenticated_identities = true
  cognito_identity_providers {
    client_id               = "${aws_cognito_user_pool_client.main.id}"
    provider_name           = "cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
    server_side_token_check = false
  }
}

# created unauth role
#  $aws_cmd iam create-role --role-name $ROLE_NAME_PREFIX-unauthenticated --assume-role-policy-document file:///tmp/unauthrole-trust-policy.json > /tmp/iamUnauthRole
resource "aws_iam_role" "unauthenticated" {
  name = "${var.role_name_prefix}-unauthenticated"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "cognito-identity.amazonaws.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "${aws_cognito_identity_pool.main.id}"
        },
        "ForAnyValue:StringLike": {
          "cognito-identity.amazonaws.com:amr": "unauthenticated"
        }
      }
    }
  ]
}
EOF
}

# create policy for unauth role
#$aws_cmd iam put-role-policy --role-name $ROLE_NAME_PREFIX-unauthenticated --policy-name CognitoPolicy --policy-document file://unauthrole.json
resource "aws_iam_role_policy" "unauthenticated" {
  name = "CognitoPolicy"
  role = "${aws_iam_role.unauthenticated.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "mobileanalytics:PutEvents",
        "cognito-sync:*"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF
}


# Create an IAM role for authenticated users
#$aws_cmd iam create-role --role-name $ROLE_NAME_PREFIX-authenticated --assume-role-policy-document file:///tmp/authrole-trust-policy.json > /tmp/iamAuthRole
resource "aws_iam_role" "authenticated" {
  name = "${var.role_name_prefix}-authenticated"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "cognito-identity.amazonaws.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "${aws_cognito_identity_pool.main.id}"
        },
        "ForAnyValue:StringLike": {
          "cognito-identity.amazonaws.com:amr": "authenticated"
        }
      }
    }
  ]
}
EOF
}

# Create an IAM role for authenticated users
#   cat authrole.json | sed 's~DDB_TABLE_ARN~'$DDB_TABLE_ARN'~' > /tmp/authrole.json
#$aws_cmd iam put-role-policy --role-name $ROLE_NAME_PREFIX-authenticated --policy-name CognitoPolicy --policy-document file:///tmp/authrole.json
resource "aws_iam_role_policy" "authenticated" {
  name = "CognitoPolicy"
  role = "${aws_iam_role.authenticated.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "mobileanalytics:PutEvents",
        "cognito-sync:*",
        "cognito-identity:*"
      ],
      "Resource": [
        "*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:BatchGetItem",
        "dynamodb:Query",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": [
        "${aws_dynamodb_table.logintrail.arn}"
      ],
      "Condition": {
        "ForAllValues:StringEquals": {
          "dynamodb:LeadingKeys": [
            "$${cognito-identity.amazonaws.com:sub}"
          ]
        }
      }
    }
  ]
}

EOF
}


# Update cognito identity with the roles
#UNAUTH_ROLE_ARN=$(perl -nle 'print $& if m{"Arn":\s*"\K([^"]*)}' /tmp/iamUnauthRole | awk -F'"' '{print $1}')
#AUTH_ROLE_ARN=$(perl -nle 'print $& if m{"Arn":\s*"\K([^"]*)}' /tmp/iamAuthRole | awk -F'"' '{print $1}')
#$aws_cmd cognito-identity set-identity-pool-roles --identity-pool-id $IDENTITY_POOL_ID --roles authenticated=$AUTH_ROLE_ARN,unauthenticated=$UNAUTH_ROLE_ARN --region $REGION
resource "aws_cognito_identity_pool_roles_attachment" "main" {
  identity_pool_id = "${aws_cognito_identity_pool.main.id}"
  roles {
    "authenticated" = "${aws_iam_role.authenticated.arn}"
    "unauthenticated" = "${aws_iam_role.unauthenticated.arn}"
  }
}

## update environment.ts template with actual IDs used by the application
data "template_file" "environment" {
  template = "${file("${path.module}/src/environments/environment.ts.tmpl")}"

  vars {
    identityPoolId = "${aws_cognito_identity_pool.main.id}"
    ddbTableName = "${aws_dynamodb_table.logintrail.name}"
    region = "${var.aws_region}"
    bucketRegion = "${var.aws_region}"
    userPoolId = "${aws_cognito_user_pool.main.id}"
    clientId = "${aws_cognito_user_pool_client.main.id}"
  }
}

output "generated_ids" {
  value = "${data.template_file.environment.rendered}"
}

resource "local_file" "environment" {
  content     = "${data.template_file.environment.rendered}"
  filename = "${path.module}/src/environments/environment.ts"
}