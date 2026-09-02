defmodule EpidemicaServerWeb.ErrorJSONTest do
  use EpidemicaServerWeb.ConnCase, async: true

  test "renders 404" do
    assert EpidemicaServerWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert EpidemicaServerWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
