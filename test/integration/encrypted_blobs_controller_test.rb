# frozen_string_literal: true

require "test_helper"

class ActiveStorageEncryptionEncryptedBlobsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @storage_dir = Dir.mktmpdir
    @other_storage_dir = Dir.mktmpdir
    @service = ActiveStorageEncryption::EncryptedDiskService.new(root: @storage_dir, private_url_policy: "stream")
    @service.name = "amazing_encrypting_disk_service" # Needed for the controller and service lookup

    # We need to set our service as the default, because the controller does lookup from the application config -
    # which does not include the service we define here
    @previous_default_service = ActiveStorage::Blob.service
    @previous_services = ActiveStorage::Blob.services

    # To catch potential issues where something goes to the default service by mistake, let's set a
    # different Service as the default
    @non_encrypted_default_service = ActiveStorage::Service::DiskService.new(root: @other_storage_dir)
    ActiveStorage::Blob.service = @non_encrypted_default_service
    ActiveStorage::Blob.services = {@service.name => @service} # That too

    # This needs to be set
    ActiveStorageEncryption::Engine.routes.default_url_options = {host: "www.example.com"}

    # We need to use a hostname for ActiveStorage which is in the Rails authorized hosts.
    # see https://stackoverflow.com/a/60573259/153886
    ActiveStorage::Current.url_options = {
      host: "www.example.com",
      protocol: "https"
    }
    freeze_time # For testing expiring tokens
    https! # So that all requests are simulated as SSL
  end

  def teardown
    unfreeze_time
    ActiveStorage::Blob.service = @previous_default_service
    ActiveStorage::Blob.services = @previous_services
    FileUtils.rm_rf(@storage_dir)
    FileUtils.rm_rf(@other_storage_dir)
  end

  def engine_routes
    ActiveStorageEncryption::Engine.routes.url_helpers
  end

  test "create_direct_upload creates a blob and returns the headers and the URL to start the upload, which are for the correct service name" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)

    params = {
      service_name: @service.name,
      blob: {
        content_type: "x-binary/sensitive",
        filename: "biometrics.sec",
        checksum: Digest::MD5.base64digest(plaintext),
        service_name: @service.name,
        byte_size: plaintext.bytesize,
        metadata: {womp: 1}
      }
    }

    post engine_routes.create_encrypted_blob_direct_upload_url, params: params

    assert_response :success

    body_payload = JSON.parse(response.body, symbolize_names: true)

    assert_equal "amazing_encrypting_disk_service", body_payload[:service_name]
    assert_equal "biometrics.sec", body_payload[:filename]
    assert_equal({womp: "1"}, body_payload[:metadata])
    assert_equal Digest::MD5.base64digest(plaintext), body_payload[:checksum]
    assert_kind_of String, body_payload[:direct_upload][:url]
    assert_kind_of Hash, body_payload[:direct_upload][:headers]
    assert_kind_of String, body_payload[:direct_upload][:headers][:"x-active-storage-encryption-key"]

    blob = ActiveStorage::Blob.find_signed!(body_payload[:signed_id])
    assert blob.encryption_key
    assert_equal blob.service, @service
  end

  test "create_direct_upload creates a blob which can then be uploaded via PUT" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)

    params = {
      service_name: @service.name,
      blob: {
        content_type: "x-binary/sensitive",
        filename: "biometrics.sec",
        checksum: Digest::MD5.base64digest(plaintext),
        service_name: @service.name,
        byte_size: plaintext.bytesize
      }
    }

    post engine_routes.create_encrypted_blob_direct_upload_url, params: params
    assert_response :success

    body_payload = JSON.parse(response.body, symbolize_names: true)
    url_to_put_to = body_payload[:direct_upload][:url]
    headers = body_payload[:direct_upload][:headers]
    put url_to_put_to, headers: headers, params: plaintext
    assert_response :no_content

    blob = ActiveStorage::Blob.find_signed!(body_payload[:signed_id])
    readback = blob.download
    assert_equal plaintext, readback
  end

  test "create_direct_upload refuses without being given an MD5 checksum" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)

    params = {
      service_name: @service.name,
      blob: {
        content_type: "x-binary/sensitive",
        filename: "biometrics.sec",
        service_name: @service.name,
        byte_size: plaintext.bytesize
      }
    }

    post engine_routes.create_encrypted_blob_direct_upload_url, params: params
    assert_response :unprocessable_entity
  end

  test "update() uploads the blob binary data to an encrypted Service using HTTP PUT" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)
    b64_md5 = Digest::MD5.base64digest(plaintext)

    key = rng.hex(12)
    encryption_key = rng.bytes(65)

    headers = @service.headers_for_direct_upload(key, content_type: "binary/octet-stream", encryption_key: encryption_key, checksum: b64_md5)
    destination_url = @service.url_for_direct_upload(key, expires_in: 5.seconds, content_type: "binary/octet-stream", content_length: plaintext.bytesize, checksum: b64_md5, encryption_key: encryption_key)

    put destination_url, headers: headers, params: plaintext
    assert_response :no_content

    assert @service.exist?(key)
    readback = @service.download(key, encryption_key: encryption_key)
    assert_equal plaintext, readback
  end

  test "update() refuses to upload if no Content-MD5 is sent with the request" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)
    b64_md5 = Digest::MD5.base64digest(plaintext)

    key = rng.hex(12)
    encryption_key = rng.bytes(65)

    headers = @service.headers_for_direct_upload(key, content_type: "binary/octet-stream", encryption_key: encryption_key, checksum: b64_md5)
    destination_url = @service.url_for_direct_upload(key, expires_in: 5.seconds, content_type: "binary/octet-stream", content_length: plaintext.bytesize, checksum: b64_md5, encryption_key: encryption_key)

    headers.delete_if { |k, _| k.downcase == "content-md5" }
    put destination_url, headers: headers, params: plaintext
    assert_response :unprocessable_entity
  end

  test "update() refuses to upload if Content-MD5 from headers differs from the one in the token" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)
    b64_md5 = Digest::MD5.base64digest(plaintext)

    key = rng.hex(12)
    encryption_key = rng.bytes(65)

    headers = @service.headers_for_direct_upload(key, content_type: "binary/octet-stream", encryption_key: encryption_key, checksum: b64_md5)
    destination_url = @service.url_for_direct_upload(key, expires_in: 5.seconds, content_type: "binary/octet-stream", content_length: plaintext.bytesize, checksum: b64_md5, encryption_key: encryption_key)

    wrong_md5 = Digest::MD5.base64digest(plaintext + "t")
    headers["content-md5"] = wrong_md5

    put destination_url, headers: headers, params: plaintext
    assert_response :unprocessable_entity
  end

  test "update() refuses to upload if no encryption key is present in the header" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)
    b64_md5 = Digest::MD5.base64digest(plaintext)

    key = rng.hex(12)
    encryption_key = rng.bytes(65)

    headers = @service.headers_for_direct_upload(key, content_type: "binary/octet-stream", encryption_key: encryption_key, checksum: b64_md5)
    destination_url = @service.url_for_direct_upload(key, expires_in: 5.seconds, content_type: "binary/octet-stream", content_length: plaintext.bytesize, checksum: b64_md5, encryption_key: encryption_key)

    headers.delete_if { |k, _| k.downcase == "x-active-storage-encryption-key" }
    put destination_url, headers: headers, params: plaintext
    assert_response :unprocessable_entity
  end

  test "update() refuses to upload if plaintext is different to the one the checksum has been calculated for" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)
    b64_md5 = Digest::MD5.base64digest(plaintext)

    key = rng.hex(12)
    encryption_key = rng.bytes(65)

    headers = @service.headers_for_direct_upload(key, content_type: "binary/octet-stream", encryption_key: encryption_key, checksum: b64_md5)
    destination_url = @service.url_for_direct_upload(key, expires_in: 5.seconds, content_type: "binary/octet-stream", content_length: plaintext.bytesize, checksum: b64_md5, encryption_key: encryption_key)

    different_plaintext = rng.bytes(plaintext.bytesize)
    refute_equal different_plaintext, plaintext

    put destination_url, headers: headers, params: different_plaintext
    assert_response :unprocessable_entity

    refute @service.exist?(key)
  end

  test "update() refuses to upload if plaintext has a different length than stated during token generation" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)
    b64_md5 = Digest::MD5.base64digest(plaintext)

    key = rng.hex(12)
    encryption_key = rng.bytes(65)

    headers = @service.headers_for_direct_upload(key, content_type: "binary/octet-stream", encryption_key: encryption_key, checksum: b64_md5)
    destination_url = @service.url_for_direct_upload(key, expires_in: 5.seconds, content_type: "binary/octet-stream", content_length: (plaintext.bytesize - 44), checksum: b64_md5, encryption_key: encryption_key)

    put destination_url, headers: headers, params: plaintext
    assert_response :unprocessable_entity
  end

  test "update() refuses to upload if the encryption key given in the header is different than the one used to generate the URL" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)
    b64_md5 = Digest::MD5.base64digest(plaintext)

    key = rng.hex(12)
    encryption_key = rng.bytes(65)

    headers = @service.headers_for_direct_upload(key, content_type: "binary/octet-stream", encryption_key: encryption_key, checksum: b64_md5)
    destination_url = @service.url_for_direct_upload(key, expires_in: 5.seconds, content_type: "binary/octet-stream", content_length: plaintext.bytesize, checksum: b64_md5, encryption_key: encryption_key)

    other_encryption_key = rng.bytes(65)
    refute_equal other_encryption_key, encryption_key

    headers["x-active-storage-encryption-key"] = Base64.strict_encode64(other_encryption_key)

    put destination_url, headers: headers, params: plaintext
    assert_response :unprocessable_entity
  end

  test "update() refuses to upload if the token in the URL has expired" do
    rng = Random.new(Minitest.seed)
    plaintext = rng.bytes(512)
    b64_md5 = Digest::MD5.base64digest(plaintext)

    key = rng.hex(12)
    encryption_key = rng.bytes(65)

    headers = @service.headers_for_direct_upload(key, content_type: "binary/octet-stream", encryption_key: encryption_key, checksum: b64_md5)
    destination_url = @service.url_for_direct_upload(key, expires_in: 5.seconds, content_type: "binary/octet-stream", content_length: plaintext.bytesize, checksum: b64_md5, encryption_key: encryption_key)

    travel 10.seconds

    put destination_url, headers: headers, params: plaintext
    assert_response :unprocessable_entity
  end
end
