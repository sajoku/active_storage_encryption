# frozen_string_literal: true

class ActiveStorageEncryption::EncryptedBlobsController < ActionController::Base
  include ActiveStorage::SetCurrent

  class InvalidParams < StandardError
  end

  DEFAULT_BLOB_STREAMING_DISPOSITION = "inline"

  self.etag_with_template_digest = false
  skip_forgery_protection

  # Accepts PUT requests for direct uploads to the EncryptedDiskService. It can actually accept
  # uploads to any encrypted service, but for S3 and GCP the upload can be done to the cloud storage
  # bucket directly.
  def update
    params = read_params_from_token_and_headers_for_put
    service = lookup_service(params[:service_name])
    key = params[:key]

    service.upload(key, request.body,
      content_type: params[:content_type],
      content_length: params[:content_length],
      checksum: params[:checksum],
      encryption_key: params[:encryption_key])
  rescue InvalidParams, ActiveStorageEncryption::IncorrectEncryptionKey, ActiveSupport::MessageVerifier::InvalidSignature, ActiveStorage::IntegrityError
    head :unprocessable_entity
  end

  # Creates a Blob record with a random encryption key and returns the details for PUTing it
  # This is only necessary because in Rails there is some disagreement regarding the service_name parameter.
  # See https://github.com/rails/rails/issues/38940
  # It does not require the service to support encryption. However, we mandate that the MD5 be provided upfront,
  # so that it gets included into the signature
  def create_direct_upload
    blob_params = params.require(:blob).permit(:filename, :byte_size, :checksum, :content_type, metadata: {})
    unless blob_params[:checksum]
      render(plain: "The `checksum' is required", status: :unprocessable_entity) and return
    end

    service = lookup_service(params.require(:service_name))
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      **blob_params.to_h.symbolize_keys,
      service_name: service.name
    )
    render json: direct_upload_json(blob)
  end

  private

  def read_params_from_token_and_headers_for_put
    token_str = params.require(:token)

    # The token params for PUT / direct upload are signed but not encrypted - the encryption key
    # is transmitted inside headers
    token_params = ActiveStorage.verifier.verify(token_str, purpose: :encrypted_put).symbolize_keys

    # Ensure we are getting sent exactly as many bytes as stated in the token
    raise InvalidParams, "Request must specify body content-length" if request.headers["content-length"].blank?

    actual_content_length = request.headers["content-length"].to_i
    expected_content_length = token_params.fetch(:content_length)
    if actual_content_length != expected_content_length
      raise InvalidParams, "content-length mismatch, expecting upload of #{expected_content_length} bytes but sent #{actual_content_length}"
    end

    # Recover the encryption key from the headers (similar to how cloud storage services do it)
    b64_encryption_key = request.headers["x-active-storage-encryption-key"]
    raise InvalidParams, "x-active-storage-encryption-key header is missing" if b64_encryption_key.blank?
    encryption_key = Base64.strict_decode64(b64_encryption_key)

    # Verify the SHA of the encryption key
    encryption_key_b64sha = Digest::SHA256.base64digest(encryption_key)
    raise InvalidParams, "Incorrect checksum for the encryption key" unless Rack::Utils.secure_compare(encryption_key_b64sha, token_params.fetch(:encryption_key_sha256))

    # Verify the Content-MD5
    b64_md5_from_headers = request.headers["content-md5"]
    raise InvalidParams, "Content-MD5 header is required" if b64_md5_from_headers.blank?
    raise InvalidParams, "Content-MD5 differs from the known checksum" unless Rack::Utils.secure_compare(b64_md5_from_headers, token_params.fetch(:checksum))

    {
      key: token_params.fetch(:key),
      encryption_key: encryption_key,
      service_name: token_params.fetch(:service_name),
      checksum: token_params[:checksum],
      content_type: token_params.fetch(:content_type),
      content_length: token_params.fetch(:content_length)
    }
  end

  def lookup_service(name)
    service = ActiveStorage::Blob.services.fetch(name) { ActiveStorage::Blob.service }
    raise InvalidParams, "#{service.name} is not providing file encryption" unless service.try(:encrypted?)
    service
  end

  def blob_args
    params.require(:blob).permit(:filename, :byte_size, :checksum, :content_type, :service_name, metadata: {}).to_h.symbolize_keys
  end

  def service_name_from_params_or_config
    params[:service_name] || ActiveStorage::Blob.service.name # ? Rails.application.config.active_storage.service.name
  end

  def direct_upload_json(blob)
    blob.as_json(root: false, methods: :signed_id).merge(direct_upload: {
      url: blob.service_url_for_direct_upload,
      headers: blob.service_headers_for_direct_upload
    })
  end
end
