# frozen_string_literal: true

require "test_helper"

class ActiveStorageEncryption::OverridesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActiveStorage::Current.url_options = {
      host: "www.example.com",
      protocol: "https"
    }
  end

  def test_encryption_key_is_set_on_encrypted_service_before_saving
    blob = ActiveStorage::Blob.create!(
      key: "yoyo",
      filename: "test.txt",
      byte_size: 10,
      checksum: "abab",
      metadata: {"identified" => true},
      content_type: "text/plain",
      encryption_key: "blabla",
      service_name: "encrypted_disk"
    )

    assert blob.valid?
    blob.encryption_key = nil
    refute blob.valid?
    assert_equal ["Encryption key must be present for this service"], blob.errors.full_messages
  end

  def test_attach_download_and_destroy_with_encryption_works
    user = User.create!
    with_uploadable_random_file do |file|
      user.file.attach(io: file, filename: "test.txt")
    end
    assert user.file.url.include?("/active-storage-encryption/blob/")
    assert user.file.blob.encryption_key
    with_uploadable_random_file do |file|
      assert_equal file.size, user.file.blob.byte_size
    end
    with_uploadable_random_file do |file|
      assert_equal file.read, user.file.download
    end
    user.file.destroy
    user.reload
    refute user.file.attached?
  end

  def test_generate_random_encryption_key_is_long_enough
    key = ActiveStorage::Blob.generate_random_encryption_key
    assert_equal 48, key.size
    assert_equal Encoding::BINARY, key.encoding
  end

  def test_service_encrypted
    blob = ActiveStorage::Blob.create!(service_name: :encrypted_disk, checksum: "yoyo", encryption_key: "haha", filename: "test", key: "hahahaha", byte_size: 50)
    assert blob.service_encrypted?
    blob_2 = ActiveStorage::Blob.create!(service_name: :test, checksum: "yoyo", filename: "test", key: "ok", byte_size: 50)
    refute blob_2.service_encrypted?
  end

  def test_create_before_direct_upload_works_with_encryption_and_without
    blob = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_before_direct_upload!(
        filename: "test_upload",
        byte_size: file.size,
        checksum: "something",
        metadata: {"identified" => true},
        service_name: "encrypted_disk"
      )
    end
    assert_raises ActiveStorage::FileNotFoundError do
      blob.download
    end

    assert blob.service_encrypted?
    assert blob.encryption_key

    blob_2 = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_before_direct_upload!(
        filename: "test_upload_2",
        byte_size: file.size,
        checksum: "something",
        metadata: {"identified" => true},
        service_name: "test"
      )
    end
    refute blob_2.service_encrypted?
    refute blob_2.encryption_key
  end

  def test_create_and_upload_works_with_encryption_and_without
    encrypted_blob = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file,
        filename: "test_upload",
        metadata: {"identified" => true},
        service_name: "encrypted_disk"
      )
    end

    assert encrypted_blob.service_encrypted?
    assert encrypted_blob.url.include?("/active-storage-encryption/blob/")
    assert encrypted_blob.encryption_key
    with_uploadable_random_file do |file|
      assert_equal file.size, encrypted_blob.byte_size
    end
    with_uploadable_random_file do |file|
      assert_equal file.read, encrypted_blob.download
    end

    unencrypted_blob = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file,
        filename: "test_upload_2",
        metadata: {"identified" => true},
        service_name: "test"
      )
    end

    refute unencrypted_blob.service_encrypted?
    assert unencrypted_blob.url.include?("/rails/active_storage/disk/")
    refute unencrypted_blob.encryption_key
    with_uploadable_random_file do |file|
      assert_equal file.size, unencrypted_blob.byte_size
    end
    with_uploadable_random_file do |file|
      assert_equal file.read, unencrypted_blob.download
    end
  end

  def test_open_temp_reads_the_content_of_the_blob_with_encryption_and_without
    encrypted_blob = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file,
        filename: "test_upload",
        metadata: {"identified" => true},
        service_name: "encrypted_disk"
      )
    end

    with_uploadable_random_file do |file|
      encrypted_blob.open do |b|
        assert_equal file.read, b.read
      end
    end

    unencrypted_blob = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file,
        filename: "test_upload_2",
        metadata: {"identified" => true},
        service_name: "test"
      )
    end

    with_uploadable_random_file do |file|
      unencrypted_blob.open do |b|
        assert_equal file.read, b.read
      end
    end
  end

  def test_can_download_a_chunk_with_encryption_and_without
    encrypted_blob = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file,
        filename: "test_upload",
        metadata: {"identified" => true},
        service_name: "encrypted_disk"
      )
    end

    chunk = encrypted_blob.download_chunk(0..5.bytes)
    with_uploadable_random_file do |file|
      assert_equal chunk, file.read(6)
    end

    unencrypted_blob = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file,
        filename: "test_upload_2",
        metadata: {"identified" => true},
        service_name: "test"
      )
    end

    chunk = unencrypted_blob.download_chunk(0..5.bytes)
    with_uploadable_random_file do |file|
      assert_equal chunk, file.read(6)
    end
  end

  def test_serializable_hash_works_with_encryption_and_without
    encrypted_blob = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file,
        filename: "test_upload",
        metadata: {"identified" => true},
        service_name: "encrypted_disk"
      )
    end
    encrypted_blob_hash = {
      "id" => encrypted_blob.id,
      "key" => encrypted_blob.key,
      "filename" => encrypted_blob.filename,
      "content_type" => encrypted_blob.content_type,
      "metadata" => encrypted_blob.metadata,
      "service_name" => encrypted_blob.service_name,
      "byte_size" => encrypted_blob.byte_size,
      "checksum" => encrypted_blob.checksum,
      "created_at" => encrypted_blob.created_at
    }
    assert_equal encrypted_blob_hash.sort, encrypted_blob.serializable_hash.sort

    unencrypted_blob = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file,
        filename: "test_upload_2",
        metadata: {"identified" => true},
        service_name: "encrypted_disk"
      )
    end
    unencrypted_blob_hash = {
      "id" => unencrypted_blob.id,
      "key" => unencrypted_blob.key,
      "filename" => unencrypted_blob.filename,
      "content_type" => encrypted_blob.content_type,
      "metadata" => unencrypted_blob.metadata,
      "service_name" => unencrypted_blob.service_name,
      "byte_size" => unencrypted_blob.byte_size,
      "checksum" => unencrypted_blob.checksum,
      "created_at" => unencrypted_blob.created_at
    }
    assert_equal unencrypted_blob_hash, unencrypted_blob.serializable_hash
  end

  def test_instance_compose_works_with_encryption_and_without
    rng = Random.new(Minitest.seed)

    encrypted_blob_1 = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file, filename: "test_upload", metadata: {"identified" => true},
        service_name: "encrypted_disk"
      )
    end
    encrypted_blob_2 = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file, filename: "test_upload_2", metadata: {"identified" => true},
        service_name: "encrypted_disk"
      )
    end
    new_encrypted_blob = ActiveStorage::Blob.create_before_direct_upload!(
      key: "new_blob_key", filename: "combined_test_upload",
      metadata: {"identified" => true}, content_type: "plain/text",
      checksum: "okok",
      byte_size: encrypted_blob_1.byte_size + encrypted_blob_2.byte_size,
      encryption_key: rng.bytes(68),
      service_name: "encrypted_disk"
    )
    new_encrypted_blob.compose([encrypted_blob_1.key, encrypted_blob_2.key], source_encryption_keys: [encrypted_blob_1.encryption_key, encrypted_blob_2.encryption_key])
    with_uploadable_random_file do |file|
      assert_equal file.read * 2, new_encrypted_blob.download
    end

    unencrypted_blob_1 = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file, filename: "test_upload_3", metadata: {"identified" => true},
        service_name: "test"
      )
    end
    unencrypted_blob_2 = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file, filename: "test_upload_4", metadata: {"identified" => true},
        service_name: "test"
      )
    end
    new_unencrypted_blob = ActiveStorage::Blob.create_before_direct_upload!(
      key: "new_blob_key_2", filename: "combined_test_upload",
      metadata: {"identified" => true}, content_type: "plain/text",
      checksum: "okok",
      byte_size: unencrypted_blob_1.byte_size + unencrypted_blob_2.byte_size
    )
    new_unencrypted_blob.compose([unencrypted_blob_1.key, unencrypted_blob_2.key])
    with_uploadable_random_file do |file|
      assert_equal file.read * 2, new_unencrypted_blob.download
    end
  end

  def test_class_compose_works_with_and_without_encryption
    rng = Random.new(Minitest.seed)

    encrypted_blob_1 = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file, filename: "test_upload", metadata: {"identified" => true},
        service_name: "encrypted_disk"
      )
    end
    encrypted_blob_2 = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file, filename: "test_upload_2", metadata: {"identified" => true},
        service_name: "encrypted_disk"
      )
    end
    new_enc_blob = ActiveStorage::Blob.compose(
      [encrypted_blob_1, encrypted_blob_2],
      content_type: "text/plain",
      filename: "composed_blob",
      metadata: {"identified" => true},
      key: "new_enc_blob",
      service_name: "encrypted_disk",
      encryption_key: rng.bytes(68)
    )
    with_uploadable_random_file do |file|
      assert_equal file.read * 2, new_enc_blob.download
    end

    unencrypted_blob_1 = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file, filename: "test_upload_3", metadata: {"identified" => true},
        service_name: "test"
      )
    end
    unencrypted_blob_2 = with_uploadable_random_file do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file, filename: "test_upload_4", metadata: {"identified" => true},
        service_name: "test"
      )
    end
    new_unencrypted_blob = ActiveStorage::Blob.compose(
      [unencrypted_blob_1, unencrypted_blob_2],
      key: "new_unencblob_key_2", filename: "combined_test_upload_2",
      metadata: {"identified" => true}, service_name: "test"
    )
    with_uploadable_random_file do |file|
      assert_equal file.read * 2, new_unencrypted_blob.download
    end
  end

  private

  def with_uploadable_random_file(size = 128, &blk)
    rng = Random.new(Minitest.seed)
    plaintext_upload_bytes = rng.bytes(size)
    StringIO.open(plaintext_upload_bytes, "rb", &blk)
  end
end
